import Foundation
private import Darwin

// tag と emit は呼出側だけが扱い、worker は入力と結果だけを共有する。
final class OrderedChunkPipeline<Input: Sendable, Output: Sendable, Tag> {
    typealias Encoder = @Sendable (Input) throws -> Output

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        let workers = DispatchGroup()
        var abandoned = false
        var results: [UInt64: Result<Output?, Error>] = [:]

        func encode(_ input: Input, id: UInt64, encoder: Encoder) {
            defer { workers.leave() }
            condition.lock()
            let shouldRun = !abandoned
            condition.unlock()
            guard shouldRun else { return }
            let result = autoreleasepool {
                Result<Output?, Error> {
                    try encoder(input)
                }
            }
            complete(result, id: id)
        }

        func complete(_ result: Result<Output?, Error>, id: UInt64) {
            condition.lock()
            defer { condition.unlock() }
            if !abandoned { results[id] = result }
            condition.broadcast()
        }

        func take(_ id: UInt64) throws -> Output? {
            condition.lock()
            defer { condition.unlock() }
            while !abandoned, results[id] == nil {
                try Task.checkCancellation()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            try Task.checkCancellation()
            guard !abandoned else { throw CancellationError() }
            return try results.removeValue(forKey: id)!.get()
        }

        func abandon() {
            condition.lock()
            defer { condition.unlock() }
            abandoned = true
            results.removeAll()
            condition.broadcast()
        }
    }

    private let threads: Int
    private let lightWeightLimit: UInt64
    private let inlineSingleThread: Bool
    private let encoder: Encoder
    private let queue: DispatchQueue
    private let state = State()
    private var items: [(id: UInt64, tag: Tag, isHeavy: Bool, weight: UInt64)] = []
    private var heavyCount = 0
    private(set) var pendingInputBytes: UInt64 = 0
    private var nextID: UInt64 = 0
    private var finished = false
    var pendingCount: Int { items.count }

    init(threads: Int, lightWeightLimit: UInt64 = 0, inlineSingleThread: Bool = false, encoder: @escaping Encoder) {
        precondition((1...64).contains(threads))
        self.threads = threads
        self.lightWeightLimit = lightWeightLimit
        self.inlineSingleThread = inlineSingleThread
        self.encoder = encoder
        queue = DispatchQueue(label: "GyoshukuKit.Compression", qos: Self.currentQoS, attributes: .concurrent)
    }

    deinit { abandon() }

    func submit(_ input: Input?, tag: Tag, weight: UInt64 = 0, inline: Bool = false,
                didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            try waitForCapacity(didEmit: didEmit, emit: emit)
            let id = nextID
            nextID = try checkedAdd(nextID, 1)
            let isHeavy = lightWeightLimit == 0 || weight == 0 || weight > lightWeightLimit
            pendingInputBytes = try checkedAdd(pendingInputBytes, weight)
            items.append((id, tag, isHeavy, weight))
            if isHeavy { heavyCount += 1 }
            if let input {
                let state = state, encoder = encoder
                state.workers.enter()
                if (threads == 1 && inlineSingleThread) || inline {
                    // 内側が逐次なら worker 自身で処理し、GCD の待機 thread を増やさない。
                    state.encode(input, id: id, encoder: encoder)
                } else {
                    queue.async(qos: Self.currentQoS, flags: .enforceQoS) {
                        state.encode(input, id: id, encoder: encoder)
                    }
                }
            } else {
                state.complete(.success(nil), id: id)
            }
        } catch {
            abandon()
            throw error
        }
    }

    // 入力を確保する前に待ち、呼出側の組立中 block も並列数の枠に含める。
    func waitForCapacity(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            while heavyCount >= threads || items.count >= 2 * threads + 1 { try emitNext(emit, didEmit: didEmit) }
        } catch {
            abandon()
            throw error
        }
    }

    func drain(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            while !items.isEmpty { try emitNext(emit, didEmit: didEmit) }
        } catch {
            abandon()
            throw error
        }
    }

    func finish(emit: (Tag, Output?) throws -> Void) throws {
        try drain(emit: emit)
        finished = true
    }

    func abandon() {
        state.abandon()
        items.removeAll()
        heavyCount = 0
        pendingInputBytes = 0
        finished = true
    }

    // 失敗で戻る前に、着手済みの source descriptor を必ず閉じる。
    func abandonAndWait() {
        abandon()
        state.workers.wait()
    }

    private func emitNext(_ emit: (Tag, Output?) throws -> Void, didEmit: ((UInt64) throws -> Void)?) throws {
        let item = items[0]
        let result = try state.take(item.id)
        try emit(item.tag, result)
        items.removeFirst()
        if item.isHeavy { heavyCount -= 1 }
        pendingInputBytes -= item.weight
        try didEmit?(item.weight)
    }

    private static var currentQoS: DispatchQoS {
        let qosClass: DispatchQoS.QoSClass
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: qosClass = .userInteractive
        case QOS_CLASS_USER_INITIATED: qosClass = .userInitiated
        case QOS_CLASS_UTILITY: qosClass = .utility
        case QOS_CLASS_BACKGROUND: qosClass = .background
        default: qosClass = .default
        }
        return DispatchQoS(qosClass: qosClass, relativePriority: 0)
    }
}
