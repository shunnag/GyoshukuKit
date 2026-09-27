import Foundation
private import Darwin

// 先読みの窓は compressionThreads、open...close だけは Step 0-P7 の上限4本。
final class SourcePrefetchLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var available: Int
    private var cancelled = false

    init(threads: Int) { available = min(threads, 4) }

    func acquire() throws {
        condition.lock()
        defer { condition.unlock() }
        while available == 0, !cancelled { condition.wait() }
        guard !cancelled else { throw CancellationError() }
        available -= 1
    }

    func release() {
        condition.lock()
        available += 1
        condition.signal()
        condition.unlock()
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
}

struct FileJob: Sendable {
    @TaskLocal static var testingBeforeWorkerOpen: (@Sendable (Int, URL) throws -> Void)?
    @TaskLocal static var testingDuringWorkerRead: (@Sendable (Int, URL) throws -> Void)?
    @TaskLocal static var testingDescriptorChange: (@Sendable (Int) -> Void)?
    @TaskLocal static var testingBeforeLstat: (@Sendable (Int, URL) throws -> Void)?

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
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(256 * 1024, size - offset))
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw WriterError.io(operation: "read", code: code)
                }
                guard count > 0 else { throw WriterError.sourceChanged(url.path) }
                offset += count
                try duringRead?(index, url)
            }
        }
        guard try FileRead.readChunk(fd, upTo: 1).isEmpty else { throw WriterError.sourceChanged(url.path) }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw WriterError.io(operation: "fstat after read", code: errno) }
        guard expected.matches(after) else { throw WriterError.sourceChanged(url.path) }
        return data
    }
}

enum ZipWork: Sendable {
    case block(DeflateBlock)
    case file(FileJob)
}
