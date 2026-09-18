import Foundation
private import Darwin

// 名前の正規化・衝突検査・ディスク探索は ArchiveWriter と共有する。
final class LHAWriter {
    private let output: FileHandle
    private let url: URL
    private let identity: (dev_t, ino_t)
    private var finished = false
    private var aborted = false
    private static let chunkSize = 256 * 1024
    private static let compressionChunkSize = 1 * 1024 * 1024

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t)) {
        self.output = output
        self.url = url
        self.identity = identity
    }

    deinit { abort() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        let entry = try LHARecords.Entry(name: name, mode: mode, size: size, date: date)
        if size > Self.compressionChunkSize {
            try addStreamed(entry: entry, name: name, size: size, read: read)
            return
        }
        // member 単位で保持し、圧縮で増える場合は原本を -lh0- として保存する。
        // ヘッダーには確定サイズと CRC が必要なので、失敗し得る読み取りも先に済ませる。
        var input = Data()
        var remaining = size
        var crc: UInt16 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(Self.chunkSize), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            input.append(chunk)
            crc = LHACRC16.update(crc, chunk)
            remaining -= UInt64(chunk.count)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        let compressed = try LH5Encoder.encode(input)
        let shrinks = compressed.count < input.count
        let payload = shrinks ? compressed : input
        let method = mode & 0xF000 == 0x4000 ? "-lhd-" : shrinks ? "-lh5-" : "-lh0-"
        try write(entry.header(method: method, packedSize: UInt32(payload.count), crc: crc))
        try write(payload)
        try Task.checkCancellation()
    }

    private func addStreamed(entry: LHARecords.Entry, name: String, size: UInt64,
                             read: (Int) throws -> Data) throws {
        let headerOffset = try output.offset()
        let placeholder = try entry.header(method: "-lh0-", packedSize: entry.size, crc: 0)
        let spool = try LHACompressionSpool(nextTo: url)
        try write(placeholder)
        let payloadOffset = try output.offset()
        var remaining = size
        var crc: UInt16 = 0
        var bits = LH5Encoder.Bits()
        var compressing = true
        var history = Data()
        while remaining > 0 {
            try Task.checkCancellation()
            var input = history
            let prefixSize = history.count
            let target = prefixSize + Int(min(UInt64(Self.compressionChunkSize), remaining))
            input.reserveCapacity(target)
            while input.count < target {
                try Task.checkCancellation()
                let requested = min(Self.chunkSize, target - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                try write(chunk)
                crc = LHACRC16.update(crc, chunk)
                input.append(chunk)
                remaining -= UInt64(chunk.count)
            }
            if compressing {
                try LH5Encoder.write(input, startingAt: prefixSize, to: &bits)
                history = Data(input.suffix(LH5Encoder.windowSize))
                try spool.write(bits.takeCompleteBytes())
                // Packed output can only grow. Once it cannot win, preserve
                // the raw bytes already written and stop doing codec work.
                compressing = spool.size < size
            }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if compressing { try spool.write(bits.finish()) }
        let shrinks = compressing && spool.size < size
        let packedSize = shrinks ? spool.size : size
        let end = try checkedAdd(payloadOffset, packedSize)
        if shrinks {
            try output.seek(toOffset: payloadOffset)
            try spool.copy(emit: write)
            try output.truncate(atOffset: end)
        }
        let header = try entry.header(method: shrinks ? "-lh5-" : "-lh0-",
                                      packedSize: UInt32(packedSize), crc: crc)
        guard header.count == placeholder.count else { throw WriterError.invalidState }
        try output.seek(toOffset: headerOffset)
        try write(header)
        try output.seek(toOffset: end)
        try Task.checkCancellation()
    }

    func finish() throws {
        try write(Data([0]))
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()
        finished = true
    }

    func abort() {
        guard !finished, !aborted else { return }
        aborted = true
        // LHA は完了済み member だけでも読める。終端を省くのではなく旧 inode 全体を無効にする。
        try? output.truncate(atOffset: 0)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            var current = stat()
            if lstat(path, &current) == 0, current.st_dev == identity.0, current.st_ino == identity.1 {
                _ = unlink(path)
            }
        }
    }

    private func write(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            try output.write(contentsOf: data[start..<min(start + Self.chunkSize, data.endIndex)])
        }
    }
}

/// Only packed bytes need a spool: the raw fallback lives in the unfinished
/// output itself. Unlink immediately, so cancellation, I/O errors, and process
/// exit cannot leave a named payload file. Memory stays independent of size.
private final class LHACompressionSpool {
    private let file: FileHandle
    private(set) var size: UInt64 = 0

    init(nextTo output: URL) throws {
        var template = Array(output.deletingLastPathComponent()
            .appendingPathComponent(".gyoshuku-lha-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw WriterError.io(operation: "create LHA spool", code: errno) }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw WriterError.io(operation: "configure LHA spool", code: code)
        }
        guard unlink(path) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw WriterError.io(operation: "unlink LHA spool", code: code)
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { try? file.close() }

    func write(_ data: Data) throws {
        let next = try checkedAdd(size, UInt64(data.count))
        try file.write(contentsOf: data)
        size = next
    }

    func copy(emit: (Data) throws -> Void) throws {
        try file.seek(toOffset: 0)
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: Int(min(256 * 1024, remaining))) ?? Data()
            guard !chunk.isEmpty else { throw WriterError.io(operation: "read LHA spool", code: EIO) }
            try emit(chunk)
            remaining -= UInt64(chunk.count)
        }
    }
}
