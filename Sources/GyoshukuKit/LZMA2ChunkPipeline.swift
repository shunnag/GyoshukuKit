import Foundation
private import Darwin

// tag と emit は呼出側だけが扱い、worker は入力と結果だけを共有する。
final class LZMA2ChunkPipeline<Tag> {
    static var chunkSize: Int { 16 * 1024 * 1024 }
    typealias Encoder = @Sendable (Data) throws -> XZLZMA2

    struct Output: Sendable {
        let compressed: XZLZMA2
        let crc: UInt32
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var abandoned = false
        var results: [UInt64: Result<Output?, Error>] = [:]

        func encode(_ input: Data, id: UInt64, checksum: Bool, encoder: Encoder) {
            condition.lock()
            let shouldRun = !abandoned
            condition.unlock()
            guard shouldRun else { return }
            let result = autoreleasepool {
                Result<Output?, Error> {
                    Output(compressed: try encoder(input), crc: checksum ? updateCRC(0, input) : 0)
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
    private let checksum: Bool
    private let encoder: Encoder
    private let queue: DispatchQueue
    private let state = State()
    private var items: [(id: UInt64, tag: Tag)] = []
    private var nextID: UInt64 = 0
    private var finished = false

    init(threads: Int, checksum: Bool = false, encoder: @escaping Encoder = LZMA2Compressor.encode) {
        precondition((1...64).contains(threads))
        self.threads = threads
        self.checksum = checksum
        self.encoder = encoder
        queue = DispatchQueue(label: "GyoshukuKit.LZMA2", qos: Self.currentQoS, attributes: .concurrent)
    }

    deinit { abandon() }

    func submit(_ input: Data?, tag: Tag, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            // 完了済みでも未出力なら枠を使い、遅い先頭による結果の蓄積を抑える。
            if items.count == threads { try emitNext(emit) }
            let id = nextID
            nextID = try checkedAdd(nextID, 1)
            items.append((id, tag))
            if let input {
                precondition(!input.isEmpty && input.count <= Self.chunkSize)
                let state = state, checksum = checksum, encoder = encoder
                queue.async(qos: Self.currentQoS, flags: .enforceQoS) {
                    state.encode(input, id: id, checksum: checksum, encoder: encoder)
                }
            } else {
                state.complete(.success(nil), id: id)
            }
        } catch {
            abandon()
            throw error
        }
    }

    func finish(emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            while !items.isEmpty { try emitNext(emit) }
            finished = true
        } catch {
            abandon()
            throw error
        }
    }

    func abandon() {
        state.abandon()
        items.removeAll()
        finished = true
    }

    private func emitNext(_ emit: (Tag, Output?) throws -> Void) throws {
        let item = items[0]
        let result = try state.take(item.id)
        try emit(item.tag, result)
        items.removeFirst()
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
