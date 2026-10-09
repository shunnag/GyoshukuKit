private import Darwin
import Foundation
import Synchronization

/// finder の表は専用 Thread だけが更新し、parser は二つの block を順番に消費する。
/// window は session 中不変。push / compact は pause の待合せ後にだけ変更する。
final class LZMAMatchFinderPipeline: @unchecked Sendable {
    static let blockSize = 4096
    static let slots = 2
    static let memorySize = slots * (blockSize * 274 * MemoryLayout<LZMAMatch>.stride
        + (blockSize + 1) * MemoryLayout<UInt32>.stride) + (512 << 10) + 4096
    @TaskLocal static var testingWorkerActivity: (@Sendable (Bool) -> Void)?
    @TaskLocal static var testingDidFindBlock: (@Sendable () -> Void)?
    private static let workers = Mutex((starts: 0, live: 0))
    static var testingWorkerCounts: (starts: Int, live: Int) { workers.withLock { $0 } }

    private let condition = NSCondition()
    private let window: UnsafeMutablePointer<UInt8>
    private var finder: LZMAMatchFinder
    private let buffers: [UnsafeMutablePointer<LZMAMatch>]
    private let offsets: [UnsafeMutablePointer<UInt32>]
    private var ready = [false, false]
    private var counts = [0, 0]
    private var writeSlot = 0
    // 下記 reader の三値は呼出側だけが操作する。
    private var readSlot = 0, readIndex = 0, readCount = 0
    private var next = 0, limit = 0, safeEnd = 0, requested = 0
    private var active = false, working = false, stopping = false, exited = false
    private var thread: Thread?
    private let activity = testingWorkerActivity
    private let didFindBlock = testingDidFindBlock

    init(finder: LZMAMatchFinder, window: UnsafeMutablePointer<UInt8>) throws {
        self.finder = finder; self.window = window
        var buffers: [UnsafeMutablePointer<LZMAMatch>] = []
        var offsets: [UnsafeMutablePointer<UInt32>] = []
        do {
            for _ in 0..<Self.slots {
                buffers.append(try lzmaAllocate(LZMAMatch.self, count: Self.blockSize * 274))
                offsets.append(try lzmaAllocate(UInt32.self, count: Self.blockSize + 1))
            }
        } catch {
            for p in buffers { free(p) }; for p in offsets { free(p) }
            throw error
        }
        self.buffers = buffers; self.offsets = offsets
        startThread()
    }

    private func startThread() {
        let worker = Thread { [self] in run() }
        worker.name = "GyoshukuKit.LZMA.finder"
        worker.stackSize = 512 << 10
        // GCD の cooperative pool を使わず、呼出側と同じ QoS を保つ。
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: worker.qualityOfService = .userInteractive
        case QOS_CLASS_USER_INITIATED: worker.qualityOfService = .userInitiated
        case QOS_CLASS_UTILITY: worker.qualityOfService = .utility
        case QOS_CLASS_BACKGROUND: worker.qualityOfService = .background
        default: worker.qualityOfService = .default
        }
        thread = worker
        worker.start()
    }

    deinit {
        // owner は window / hash の解放前に必ず stopAndWait を呼ぶ。
        for p in buffers { free(p) }; for p in offsets { free(p) }
    }

    func begin(limit: Int) {
        condition.lock()
        // sizeMismatchは入力を変更しない検査エラー。join後も状態を保ち、再入力を受け付ける。
        if exited { stopping = false; exited = false; startThread() }
        self.limit = limit
        // available >= 273 の位置だけ投機的に処理する。残りは要求時の limit に従う。
        safeEnd = max(0, limit - 272)
        active = true
        condition.broadcast(); condition.unlock()
    }

    func pause() {
        condition.lock(); active = false
        condition.broadcast()
        while working { condition.wait() }
        condition.unlock()
    }

    func compact(by drop: Int) {
        // pause 済み。候補は距離だけを持つので block 内の変換は不要。
        condition.lock()
        next -= drop; limit -= drop; safeEnd -= drop; requested -= drop
        condition.unlock()
    }

    func stopAndWait() {
        condition.lock(); stopping = true; active = false
        condition.broadcast()
        while !exited { condition.wait() }
        condition.unlock()
        thread = nil
    }

    @inline(__always) func matches(at position: Int, into result: UnsafeMutablePointer<LZMAMatch>) -> Int {
        acquire(through: position + 1)
        let starts = offsets[readSlot]
        let start = Int(starts[readIndex]), count = Int(starts[readIndex + 1]) - start
        if count > 0 { result.update(from: buffers[readSlot] + start, count: count) }
        readIndex += 1
        if readIndex == readCount { recycle() }
        return count
    }

    func skip(from position: Int, to target: Int) {
        var position = position
        while position < target {
            acquire(through: target)
            let count = min(target - position, readCount - readIndex)
            readIndex += count; position += count
            if readIndex == readCount { recycle() }
        }
    }

    @inline(__always) private func acquire(through target: Int) {
        if readCount > 0 { return }
        condition.lock()
        requested = max(requested, target)
        condition.broadcast()
        while !ready[readSlot] { condition.wait() }
        readCount = counts[readSlot]
        condition.unlock()
    }

    private func recycle() {
        condition.lock(); ready[readSlot] = false
        readSlot = (readSlot + 1) % Self.slots; readIndex = 0; readCount = 0
        condition.broadcast(); condition.unlock()
    }

    private func run() {
        // hot loopの状態はThreadのstackへ置き、class propertyの排他アクセスを位置ごとに行わない。
        var finder = self.finder
        Self.workers.withLock { $0.starts += 1; $0.live += 1 }
        activity?(true)
        condition.lock()
        while !stopping {
            let bound = max(safeEnd, requested)
            guard active && !ready[writeSlot] && next < bound else {
                condition.wait(); continue
            }
            let slot = writeSlot, start = next, end = min(bound, start + Self.blockSize)
            let availableEnd = limit
            working = true
            condition.unlock()
            let output = buffers[slot], starts = offsets[slot]
            var used = 0
            starts[0] = 0
            for position in start..<end {
                used += finder.matches(UnsafePointer(window + position), available: availableEnd - position,
                    into: output + used, extendMatches: false, recordShortMatches: !finder.tree)
                starts[position - start + 1] = UInt32(used)
            }
            didFindBlock?()
            condition.lock()
            next = end; counts[slot] = end - start; ready[slot] = true
            writeSlot = (slot + 1) % Self.slots
            working = false
            condition.broadcast()
        }
        self.finder = finder
        condition.unlock()
        activity?(false)
        Self.workers.withLock { $0.live -= 1 }
        condition.lock(); exited = true; condition.broadcast(); condition.unlock()
    }
}
