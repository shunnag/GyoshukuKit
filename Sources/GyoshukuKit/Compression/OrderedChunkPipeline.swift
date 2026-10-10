import Foundation
private import Darwin

// tag と emit は呼出側だけが扱い、worker は入力と結果だけを共有する。
final class OrderedChunkPipeline<Input: Sendable, Output: Sendable, Tag> {
    typealias Encoder = @Sendable (Input) throws -> Output

    // 入力は一workerだけが所有する。GCDのclosureが残ってもjoin前に捕捉入力を解放する。
    private final class Work: @unchecked Sendable {
        var input: Input?
        let early: Bool
        let borrowsThread: Bool
        init(_ input: Input, early: Bool = false, borrowsThread: Bool = false) {
            self.input = input; self.early = early; self.borrowsThread = borrowsThread
        }
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        let workers = DispatchGroup()
        var abandoned = false
        var results: [UInt64: Result<Output?, Error>] = [:]
        // 枠待ち中のGCD blockも未着手。claimとcounter更新を同じlockで確定する。
        var pending: [UInt64: Work] = [:]
        var normalWorkers = 0
        var borrowedEarlyWorkers = 0

        func enqueue(_ work: Work, id: UInt64) {
            condition.lock()
            pending[id] = work
            if work.borrowsThread { borrowedEarlyWorkers += 1 }
            workers.enter()
            condition.unlock()
        }

        // conditionのlock内だけで使う。着手したbodyだけがworker枠を持つ。
        private func canRun(_ work: Work, threads: Int) -> Bool {
            !(work.borrowsThread && normalWorkers >= threads)
                && !(!work.early && borrowedEarlyWorkers > 0 && normalWorkers >= threads - borrowedEarlyWorkers)
        }

        private func claim(_ id: UInt64, threads: Int) -> Work? {
            guard !abandoned, let work = pending[id], canRun(work, threads: threads) else { return nil }
            pending.removeValue(forKey: id)
            if !work.early { normalWorkers += 1 }
            condition.broadcast()
            return work
        }

        private func claimNext(_ id: UInt64, threads: Int, helpBorrowed: Bool) -> (id: UInt64, work: Work)? {
            if let work = claim(id, threads: threads) { return (id, work) }
            // 通常jobが借用枠を待つ場合は、同じpipelineの先行jobを先に進める。
            if helpBorrowed, pending[id] != nil,
               let borrowed = pending.first(where: { $0.value.borrowsThread && canRun($0.value, threads: threads) }),
               let work = claim(borrowed.key, threads: threads) { return (borrowed.key, work) }
            return nil
        }

        func run(id: UInt64, threads: Int, helpBorrowed: Bool = false, encoder: Encoder) {
            condition.lock()
            defer { condition.unlock() }
            // callerが処理済み、またはabandon済みなら、遅れて来たblockは何も所有しない。
            while !abandoned, pending[id] != nil {
                if let claimed = claimNext(id, threads: threads, helpBorrowed: helpBorrowed) {
                    condition.unlock()
                    encode(claimed.work, id: claimed.id, encoder: encoder)
                    condition.lock()
                } else {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
            }
        }

        private func encode(_ work: Work, id: UInt64, encoder: Encoder) {
            defer {
                work.input = nil
                condition.lock()
                if work.borrowsThread { borrowedEarlyWorkers -= 1 }
                if !work.early { normalWorkers -= 1 }
                condition.broadcast()
                condition.unlock()
                workers.leave()
            }
            autoreleasepool {
                let result = Result<Output?, Error> { try encoder(work.input!) }
                complete(result, id: id)
            }
        }

        func complete(_ result: Result<Output?, Error>, id: UInt64) {
            condition.lock()
            defer { condition.unlock() }
            if !abandoned { results[id] = result }
            condition.broadcast()
        }

        func isComplete(_ id: UInt64) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return results[id] != nil
        }

        func take(_ id: UInt64, threads: Int, cancellation: CompressionCancellation?, remove: Bool = true,
                  encoder: Encoder) throws -> Result<Output?, Error> {
            condition.lock()
            defer { condition.unlock() }
            var waited = false
            while !abandoned, results[id] == nil {
                try cancellation?.check()
                try Task.checkCancellation()
                // 通常は先にGCDへ譲り、着手済みcodecの取消し待ちは従来どおりpollする。
                if !waited {
                    waited = true
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                    continue
                }
                if let claimed = claimNext(id, threads: threads, helpBorrowed: true) {
                    condition.unlock()
                    encode(claimed.work, id: claimed.id, encoder: encoder)
                    condition.lock()
                } else {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
            }
            try cancellation?.check()
            try Task.checkCancellation()
            guard !abandoned else { throw CancellationError() }
            return remove ? results.removeValue(forKey: id)! : results[id]!
        }

        func abandon() {
            condition.lock()
            defer { condition.unlock() }
            abandoned = true
            results.removeAll()
            // 未着手分はここでleaveし、joinは着手済みbodyだけを待つ。queued blockには入力を残さない。
            for work in pending.values {
                work.input = nil
                if work.borrowsThread { borrowedEarlyWorkers -= 1 }
                workers.leave()
            }
            pending.removeAll()
            condition.broadcast()
        }
    }

    private let threads: Int
    private let lightWeightLimit: UInt64
    private let inlineSingleThread: Bool
    private let encoder: Encoder
    private let failure: (Tag, Error) -> Error
    private let cancellation: CompressionCancellation?
    private let queue: DispatchQueue
    private let state = State()
    private var items: [(id: UInt64, tag: Tag, isHeavy: Bool, reserved: Bool, weight: UInt64)] = []
    private var heavyCount = 0
    private var reservedCount = 0
    private(set) var pendingInputBytes: UInt64 = 0
    private var nextID: UInt64 = 0
    private var finished = false
    // 先行結果は出力窓に入れず、元のindexでtagを付けるまで失敗も保持する。一括追加につき一枠。
    struct Early: Sendable {
        fileprivate let id: UInt64
        fileprivate let weight: UInt64
    }
    private var early: Early?
    var pendingCount: Int { items.count }
    var hasReservedItem: Bool { reservedCount > 0 }
    var firstTag: Tag? { items.first?.tag }

    init(threads: Int, lightWeightLimit: UInt64 = 0, inlineSingleThread: Bool = false, cancellation: CompressionCancellation? = nil,
         queue: DispatchQueue? = nil,
         failure: @escaping (Tag, Error) -> Error = { _, error in error }, encoder: @escaping Encoder) {
        precondition(WriterOptions.compressionThreadsRange.contains(threads))
        self.threads = threads
        self.lightWeightLimit = lightWeightLimit
        self.inlineSingleThread = inlineSingleThread
        self.encoder = encoder
        self.failure = failure
        self.cancellation = cancellation
        self.queue = queue ?? DispatchQueue(label: "GyoshukuKit.Compression", qos: Self.currentQoS, attributes: .concurrent)
    }

    deinit { abandon() }

    // 帰属の有効期間は呼出側が管理し、完了済みworkerの失敗も出力時のtagで解決する。
    func updatePendingTags(_ update: (inout Tag) -> Void) {
        for index in items.indices { update(&items[index].tag) }
    }

    func startEarly(weight: UInt64, borrowsThread: Bool = false, input: () throws -> Input) throws -> Early {
        guard !finished, early == nil else { throw WriterError.invalidState }
        try Task.checkCancellation()
        let ticket = Early(id: nextID, weight: weight)
        nextID = try checkedAdd(nextID, 1)
        pendingInputBytes = try checkedAdd(pendingInputBytes, weight)
        early = ticket
        do {
            let work = Work(try input(), early: true, borrowsThread: borrowsThread)
            let state = state, encoder = encoder, threads = threads
            state.enqueue(work, id: ticket.id)
            queue.async(qos: Self.currentQoS, flags: .enforceQoS) {
                // 専用codecを持つ7zは通常窓の枠を借りない。
                state.run(id: ticket.id, threads: threads, encoder: encoder)
            }
        } catch { state.complete(.failure(error), id: ticket.id) }
        return ticket
    }

    // 後続の長いstreamへ専用codecを貸す前に終了を待つ。失敗は元のindexまで報告しない。
    func joinEarly(_ ticket: Early) throws {
        guard early?.id == ticket.id else { throw WriterError.invalidState }
        _ = try state.take(ticket.id, threads: threads, cancellation: cancellation, remove: false, encoder: encoder)
    }

    func isEarlyComplete(_ ticket: Early) -> Bool { state.isComplete(ticket.id) }

    func submitEarly(_ ticket: Early, tag: Tag, reserved: Bool = false,
                     emit: (Tag, Output?) throws -> Void) throws {
        guard !finished, early?.id == ticket.id else { throw WriterError.invalidState }
        try waitForCapacity(reserved: reserved, emit: emit)
        items.append((ticket.id, tag, true, reserved, ticket.weight))
        if reserved { reservedCount += 1 } else { heavyCount += 1 }
        early = nil
    }

    func submit(_ input: Input?, tag: Tag, weight: UInt64 = 0, inline: Bool = false, reserved: Bool = false,
                didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            try waitForCapacity(reserved: reserved, didEmit: didEmit, emit: emit)
            let id = nextID
            nextID = try checkedAdd(nextID, 1)
            let isHeavy = lightWeightLimit == 0 || weight == 0 || weight > lightWeightLimit
            pendingInputBytes = try checkedAdd(pendingInputBytes, weight)
            items.append((id, tag, isHeavy, reserved, weight))
            if reserved { reservedCount += 1 }
            else if isHeavy { heavyCount += 1 }
            if let input {
                let state = state, encoder = encoder
                let work = Work(input)
                state.enqueue(work, id: id)
                if (threads == 1 && inlineSingleThread) || inline {
                    // 内側が逐次なら worker 自身で処理し、GCD の待機 thread を増やさない。
                    state.run(id: id, threads: threads, helpBorrowed: true, encoder: encoder)
                } else {
                    let threads = threads
                    queue.async(qos: Self.currentQoS, flags: .enforceQoS) {
                        state.run(id: id, threads: threads, encoder: encoder)
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
    func waitForCapacity(reserved: Bool = false, didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            // 長いstreamは通常窓と別に一枠だけ。二本目は先頭から出力して枠を返す。
            while (reserved ? reservedCount > 0 : heavyCount >= threads)
                || items.count >= 2 * threads + (reserved ? 2 : 1) { try emitNext(emit, didEmit: didEmit) }
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
        reservedCount = 0
        pendingInputBytes = 0
        early = nil
        finished = true
    }

    // 失敗で戻る前に、着手済みの source descriptor を必ず閉じる。
    func abandonAndWait() {
        abandon()
        state.workers.wait()
    }

    // 内部 codec の予約待ちでも先頭だけを出力し、残りの窓を保つ。
    func emitNext(_ emit: (Tag, Output?) throws -> Void, didEmit: ((UInt64) throws -> Void)? = nil) throws {
        guard !finished, !items.isEmpty else { throw WriterError.invalidState }
        let item = items[0]
        do {
            let result = try state.take(item.id, threads: threads, cancellation: cancellation, encoder: encoder).get()
            try emit(item.tag, result)
            items.removeFirst()
            if item.reserved { reservedCount -= 1 }
            else if item.isHeavy { heavyCount -= 1 }
            pendingInputBytes -= item.weight
            try didEmit?(item.weight)
        } catch {
            abandon()
            throw failure(item.tag, error)
        }
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
