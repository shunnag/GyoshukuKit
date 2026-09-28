import Foundation
private import Darwin
internal import KaitoKit

// buffer を満たす範囲だけを読み、飛び越える範囲と patch の前に flush する。
struct ZipCopyEngine {
    @TaskLocal static var writeObserver: (@Sendable (UInt64, Int) -> Void)?
    @TaskLocal static var testingBufferSize: Int = 4 * 1024 * 1024
    private let descriptor: Int32
    private var buffer: Data
    private var used = 0
    private var start: UInt64 = 0
    var meter: ZipCommitMeter
    private var sharedMeter: CommitProgressMeter?

    init(descriptor: Int32, totalBytes: UInt64) {
        self.descriptor = descriptor
        buffer = Data(count: max(1, Self.testingBufferSize))
        meter = ZipCommitMeter(totalBytes: totalBytes)
    }

    init(descriptor: Int32, meter: CommitProgressMeter?) {
        self.init(descriptor: descriptor, totalBytes: 0)
        self.sharedMeter = meter
    }

    mutating func flush(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        guard used > 0 else { return }
        try buffer.withUnsafeBytes { bytes in
            try Self.pwrite(descriptor, bytes: UnsafeRawBufferPointer(rebasing: bytes[..<used]), at: start)
        }
        try meter.wrote(used, progress: progress)
        try sharedMeter?.advance(UInt64(used))
        start += UInt64(used)
        used = 0
    }

    private mutating func move(to offset: UInt64, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        if offset != start + UInt64(used) {
            try flush(progress: progress)
            start = offset
        }
    }

    mutating func append(_ bytes: Data, range: Range<Int>? = nil, at offset: UInt64,
                         progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try move(to: offset, progress: progress)
        let range = range ?? bytes.startIndex..<bytes.endIndex
        precondition(range.lowerBound >= bytes.startIndex && range.upperBound <= bytes.endIndex)
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            if used == 0 { try Task.checkCancellation() }
            let count = min(buffer.count - used, range.upperBound - cursor)
            buffer.withUnsafeMutableBytes { target in
                bytes.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: used).copyMemory(
                        from: source.baseAddress!.advanced(by: cursor - bytes.startIndex), byteCount: count)
                }
            }
            used += count
            cursor += count
            if used == buffer.count { try flush(progress: progress) }
        }
    }

    mutating func appendCentral(_ bytes: Data, range: Range<Int>, localOffset: UInt64, at offset: UInt64,
                                progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        precondition(range.count >= 46 && range.lowerBound >= bytes.startIndex && range.upperBound <= bytes.endIndex)
        precondition(localOffset < ZipRecords.limit)
        try move(to: offset, progress: progress)
        if range.count <= buffer.count - used {
            if used == 0 { try Task.checkCancellation() }
            let changed = bytes.zip32(range.lowerBound + 42) != UInt32(localOffset)
            var encoded = UInt32(localOffset).littleEndian
            buffer.withUnsafeMutableBytes { target in
                bytes.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: used).copyMemory(
                        from: source.baseAddress!.advanced(by: range.lowerBound - bytes.startIndex), byteCount: range.count)
                }
                if changed {
                    withUnsafeBytes(of: &encoded) { field in
                        target.baseAddress!.advanced(by: used + 42).copyMemory(from: field.baseAddress!, byteCount: 4)
                    }
                }
            }
            used += range.count
            if used == buffer.count { try flush(progress: progress) }
        } else {
            // buffer 境界でも record 全体の一時 Data を作らない。
            try append(bytes, range: range.lowerBound..<(range.lowerBound + 42), at: offset, progress: progress)
            var encoded = Data()
            encoded.le(UInt32(localOffset))
            try append(encoded, at: offset + 42, progress: progress)
            try append(bytes, range: (range.lowerBound + 46)..<range.upperBound, at: offset + 46, progress: progress)
        }
    }

    mutating func copy(_ range: Range<UInt64>, from source: ArchiveFileSource, to offset: UInt64,
                       progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try move(to: offset, progress: progress)
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            try Task.checkCancellation()
            let count = Int(min(UInt64(buffer.count - used), range.upperBound - cursor))
            try buffer.withUnsafeMutableBytes { bytes in
                try source.readExactly(into: UnsafeMutableRawBufferPointer(rebasing: bytes[used..<(used + count)]), at: cursor)
            }
            used += count
            cursor += UInt64(count)
            if used == buffer.count { try flush(progress: progress) }
        }
    }

    mutating func patch(_ bytes: Data, at offset: UInt64,
                        progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try flush(progress: progress)
        try bytes.withUnsafeBytes { try Self.pwrite(descriptor, bytes: $0, at: offset) }
        try meter.wrote(bytes.count, progress: progress)
        try sharedMeter?.advance(UInt64(bytes.count))
    }

    // snapshot の ByteSource を開き直さずに運び、書く前の byte を区切りごとに照合する。
    mutating func copy(_ range: Range<UInt64>, from source: any ByteSource, to offset: UInt64,
                       compressedCRC32: UInt32? = nil) throws {
        guard range.upperBound <= source.length else { throw UpdaterError.sourceChanged }
        try move(to: offset, progress: nil)
        var cursor = range.lowerBound
        var crc: UInt32 = 0
        while cursor < range.upperBound {
            try Task.checkCancellation()
            let count = Int(min(UInt64(buffer.count - used), range.upperBound - cursor))
            try buffer.withUnsafeMutableBytes { bytes in
                var filled = 0
                while filled < count {
                    let n = try source.read(into: .init(rebasing: bytes[(used + filled)..<(used + count)]),
                                            at: cursor + UInt64(filled))
                    guard n > 0, n <= count - filled else { throw UpdaterError.sourceChanged }
                    filled += n
                }
                if compressedCRC32 != nil { crc = updateCRC(crc, .init(rebasing: bytes[used..<(used + count)])) }
            }
            used += count
            cursor += UInt64(count)
            if used == buffer.count { try flush(progress: nil) }
        }
        if let compressedCRC32, crc != compressedCRC32 { throw UpdaterError.sourceChanged }
    }

    static func pwrite(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < bytes.count {
            try Task.checkCancellation()
            let position = try checkedAdd(offset, UInt64(done))
            guard position <= UInt64(Int64.max) else { throw WriterError.sizeOverflow }
            let count = Darwin.pwrite(descriptor, bytes.baseAddress!.advanced(by: done), bytes.count - done, off_t(position))
            if count < 0 {
                if errno == EINTR { continue }
                throw WriterError.io(operation: "pwrite archive", code: errno)
            }
            guard count > 0 else { throw WriterError.io(operation: "pwrite archive", code: EIO) }
            writeObserver?(position, count)
            done += count
        }
    }
}
