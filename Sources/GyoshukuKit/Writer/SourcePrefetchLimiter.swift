import Foundation
private import Darwin

// 先読みの窓は compressionThreads 件、同時に open している source は最大 4 本（`init(threads:)` の `min(threads, 4)`）。
final class SourcePrefetchLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var available: Int
    private var cancelled = false

    init(threads: Int) { available = min(threads, 4) }

    func acquire() throws {
        condition.lock()
        defer { condition.unlock() }
        while available == 0, !cancelled {
            try Task.checkCancellation()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        available -= 1
    }

    func release() {
        condition.lock()
        available += 1
        condition.signal()
        condition.unlock()
    }

    func check() throws {
        try Task.checkCancellation()
        condition.lock()
        defer { condition.unlock() }
        if cancelled { throw CancellationError() }
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

struct Prefetched: Sendable {
    let data: Data
    let crc: UInt32
    let spool: OrderedEntrySpool?

    init(data: Data, crc: UInt32, spool: OrderedEntrySpool? = nil) {
        self.data = data; self.crc = crc; self.spool = spool
    }
}

struct FileJob: Sendable {
    @TaskLocal static var testingBeforeWorkerOpen: (@Sendable (Int, URL) throws -> Void)?
    @TaskLocal static var testingDuringWorkerRead: (@Sendable (Int, URL) throws -> Void)?
    @TaskLocal static var testingDescriptorChange: (@Sendable (Int) -> Void)?

    let index: Int
    let addition: ArchiveAddition
    let path: [CChar]
    let expected: DiskSignature
    let size: Int
    let deflate: Bool
    let limiter: SourcePrefetchLimiter
    // GCD は TaskLocal を継承しないので、呼出側で値を取り込む。
    let beforeOpen = testingBeforeWorkerOpen
    let duringRead = testingDuringWorkerRead
    let descriptorChange = testingDescriptorChange

    func run(encode: (DeflateBlock) throws -> Data) throws -> Prefetched {
        do {
            let data = try read()
            let crc = updateCRC(0, data)
            return Prefetched(data: deflate ? try encode(.init(input: data, dictionary: Data(), final: true)) : data, crc: crc)
        } catch { throw additionFailure(error, index: index, addition: addition) }
    }

    private func read() throws -> Data {
        try withDescriptor { fd in
            var data = Data(count: size)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < size {
                    try limiter.check()
                    let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(IOChunk.size, size - offset))
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw WriterError.io(operation: "read", code: code)
                    }
                    guard count > 0 else { throw WriterError.sourceChanged(addition.sourceURL!.path) }
                    offset += count
                    try duringRead?(index, addition.sourceURL!)
                }
            }
            guard try FileRead.readChunk(fd, upTo: 1).isEmpty else { throw WriterError.sourceChanged(addition.sourceURL!.path) }
            return data
        }
    }

    // 大項目も同じ open・署名・descriptor 上限を使い、全入力を保持せず block ごとに読む。
    // read の EOF 検査で署名も確定し、最後の block を投入する前に変更を検出する。
    func withReader<T>(_ body: ((Int) throws -> Data) throws -> T) throws -> T {
        try withDescriptor { fd in
            try body { requested in
                try limiter.check()
                let data = try FileRead.readChunk(fd, upTo: requested)
                try duringRead?(index, addition.sourceURL!)
                if data.isEmpty { try verifyDescriptor(fd) }
                return data
            }
        }
    }

    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try limiter.acquire()
        defer { limiter.release() }
        let url = addition.sourceURL!
        try beforeOpen?(index, url)
        let fd = path.withUnsafeBufferPointer { Darwin.open($0.baseAddress!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw WriterError.io(operation: "open source", code: errno) }
        descriptorChange?(1)
        defer { Darwin.close(fd); descriptorChange?(-1) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw WriterError.io(operation: "fstat source", code: errno) }
        guard expected.matches(opened), opened.st_size >= 0 else { throw WriterError.sourceChanged(url.path) }
        let result = try body(fd)
        try verifyDescriptor(fd)
        return result
    }

    private func verifyDescriptor(_ fd: Int32) throws {
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw WriterError.io(operation: "fstat after read", code: errno) }
        guard expected.matches(after) else { throw WriterError.sourceChanged(addition.sourceURL!.path) }
    }

    // 先行項目の callback 中に置換された source も、最終出力の前に検査する。
    func verifySource() throws {
        var info = stat()
        guard path.withUnsafeBufferPointer({ lstat($0.baseAddress!, &info) }) == 0 else {
            throw WriterError.io(operation: "lstat after read", code: errno)
        }
        guard expected.matches(info) else { throw WriterError.sourceChanged(addition.sourceURL!.path) }
    }
}
