import Foundation
private import Darwin

// 名前の正規化・衝突検査・ディスク探索は ArchiveWriter と共有する。
final class LHAWriter {
    private let output: FileHandle
    private let url: URL
    private var finished = false
    private var aborted = false
    private static let chunkSize = 256 * 1024
    static let compressionChunkSize = 1 * 1024 * 1024
    private let threads: Int
    private let encoder: @Sendable (Data) throws -> Data
    private struct Pending {
        let entry: LHARecords.Entry
        let crc: UInt16
        let input: Data
        let directory: Bool
    }
    private let pipeline: OrderedChunkPipeline<Data, Data?, Pending>?

    struct MemberRecord {
        let headerOffset: UInt64
        let headerLength: UInt64
        let dataLength: UInt64
        let method: String
        let rawName: Data
    }
    var recordsMembers = false
    private(set) var memberRecords: [MemberRecord] = []

    init(output: FileHandle, url: URL, identity _: (dev_t, ino_t), threads: Int = 1,
         encoder: @escaping @Sendable (Data) throws -> Data = LH5Encoder.encode) {
        precondition((1...64).contains(threads))
        self.output = output
        self.url = url
        self.threads = threads
        self.encoder = encoder
        pipeline = threads > 1 ? OrderedChunkPipeline(threads: threads) { input in
            let compressed = try encoder(input)
            return compressed.count < input.count ? compressed : nil
        } : nil
    }

    deinit { abort() }

    var pendingInputBytes: UInt64 { pipeline?.pendingInputBytes ?? 0 }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?) throws {
        try pipeline?.drain(didEmit: didEmit, emit: emit)
    }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        guard !finished, !aborted else { throw WriterError.invalidState }
        try Task.checkCancellation()
        let entry = try LHARecords.Entry(name: name, mode: mode, size: size, date: date)
        if size > Self.compressionChunkSize {
            try pipeline?.drain(emit: emit)
            if threads == 1 { try addStreamed(entry: entry, name: name, size: size, read: read) }
            else { try addStreamedParallel(entry: entry, name: name, size: size, read: read) }
            return
        }
        try pipeline?.waitForCapacity(emit: emit)
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
        if let pipeline {
            let directory = mode & 0xF000 == 0x4000
            try pipeline.submit(directory ? nil : input,
                tag: Pending(entry: entry, crc: crc, input: input, directory: directory), weight: UInt64(input.count), emit: emit)
            return
        }
        let compressed = try encoder(input)
        let shrinks = compressed.count < input.count
        let payload = shrinks ? compressed : input
        let method = mode & 0xF000 == 0x4000 ? "-lhd-" : shrinks ? "-lh5-" : "-lh0-"
        try writeMember(entry, method: method, payload: payload, crc: crc)
        try Task.checkCancellation()
    }

    private func emit(_ pending: Pending, _ result: Data??) throws {
        let compressed = result ?? nil
        let method = pending.directory ? "-lhd-" : compressed == nil ? "-lh0-" : "-lh5-"
        try writeMember(pending.entry, method: method, payload: compressed ?? pending.input, crc: pending.crc)
    }

    private func writeMember(_ entry: LHARecords.Entry, method: String, payload: Data, crc: UInt16) throws {
        let offset = recordsMembers ? try output.offset() : 0
        let header = try entry.header(method: method, packedSize: UInt32(payload.count), crc: crc)
        try write(header)
        try write(payload)
        record(entry, offset: offset, headerLength: header.count, dataLength: UInt64(payload.count), method: method)
    }

    private func record(_ entry: LHARecords.Entry, offset: UInt64, headerLength: Int, dataLength: UInt64, method: String) {
        guard recordsMembers else { return }
        let name = Data(entry.directory.map { $0 == 0xFF ? 0x2F : $0 }) + entry.filename
        memberRecords.append(MemberRecord(headerOffset: offset, headerLength: UInt64(headerLength),
            dataLength: dataLength, method: method, rawName: name))
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
        record(entry, offset: headerOffset, headerLength: header.count, dataLength: packedSize,
               method: shrinks ? "-lh5-" : "-lh0-")
        try Task.checkCancellation()
    }

    private struct Piece: Sendable {
        let input: Data
        let prefix: Int
    }
    private struct PieceOutput: Sendable {
        let bytes: Data
        let remainder: LH5Encoder.Bits.Remainder
    }
    private enum CompressionStopped: Error { case stored }

    private func addStreamedParallel(entry: LHARecords.Entry, name: String, size: UInt64,
                                     read: (Int) throws -> Data) throws {
        let headerOffset = try output.offset()
        let placeholder = try entry.header(method: "-lh0-", packedSize: entry.size, crc: 0)
        let spool = try LHACompressionSpool(nextTo: url)
        try write(placeholder)
        let payloadOffset = try output.offset()
        let pieces = OrderedChunkPipeline<Piece, PieceOutput, Void>(threads: threads) { piece in
            var bits = LH5Encoder.Bits()
            try LH5Encoder.write(piece.input, startingAt: piece.prefix, to: &bits)
            let remainder = bits.remainder
            return PieceOutput(bytes: bits.takeCompleteBytes(), remainder: remainder)
        }
        var remaining = size
        var crc: UInt16 = 0
        var bits = LH5Encoder.Bits()
        var history = Data()
        var compressing = true
        func emitPiece(_: Void, _ result: PieceOutput?) throws {
            guard let result else { throw WriterError.invalidState }
            bits.append(result.bytes, remainder: result.remainder)
            try spool.write(bits.takeCompleteBytes())
            // emit 中に直接 abandon すると、pipeline の取出し途中の tag を消してしまう。
            // 内部の停止だけを捕捉し、pipeline 自身の失敗時の abandon を通す。
            if spool.size >= size { throw CompressionStopped.stored }
        }
        while remaining > 0 {
            try Task.checkCancellation()
            if compressing {
                do { try pieces.waitForCapacity(emit: emitPiece) }
                catch CompressionStopped.stored { compressing = false; history = Data() }
            }
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
                history = Data(input.suffix(LH5Encoder.windowSize))
                try pieces.submit(Piece(input: input, prefix: prefixSize), tag: (), emit: emitPiece)
            }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if compressing {
            do { try pieces.finish(emit: emitPiece) }
            catch CompressionStopped.stored { compressing = false }
        }
        if compressing { try spool.write(bits.finish()) }
        let shrinks = compressing && spool.size < size
        let packedSize = shrinks ? spool.size : size
        let end = try checkedAdd(payloadOffset, packedSize)
        if shrinks {
            try output.seek(toOffset: payloadOffset)
            try spool.copy(emit: write)
            try output.truncate(atOffset: end)
        }
        let method = shrinks ? "-lh5-" : "-lh0-"
        let header = try entry.header(method: method, packedSize: UInt32(packedSize), crc: crc)
        guard header.count == placeholder.count else { throw WriterError.invalidState }
        try output.seek(toOffset: headerOffset)
        try write(header)
        try output.seek(toOffset: end)
        record(entry, offset: headerOffset, headerLength: header.count, dataLength: packedSize, method: method)
        try Task.checkCancellation()
    }

    func endMembers() throws -> UInt64 {
        guard !finished, !aborted else { throw WriterError.invalidState }
        try pipeline?.drain(emit: emit)
        let end = try output.offset()
        finished = true
        return end
    }

    func finish() throws {
        guard !finished, !aborted else { throw WriterError.invalidState }
        try pipeline?.drain(emit: emit)
        try write(Data([0]))
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()
        finished = true
    }

    func abort() {
        guard !finished, !aborted else { return }
        aborted = true
        pipeline?.abandon()
        // LHA は完了済み member だけでも読める。終端を省くのではなく旧 inode 全体を無効にする。
        ArchiveOwnedFile.remove(url: url, descriptor: output.fileDescriptor)
        try? output.truncate(atOffset: 0)
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
            let chunk = try FileRead.readChunk(file.fileDescriptor, upTo: Int(min(256 * 1024, remaining)))
            guard !chunk.isEmpty else { throw WriterError.io(operation: "read LHA spool", code: EIO) }
            try emit(chunk)
            remaining -= UInt64(chunk.count)
        }
    }
}
