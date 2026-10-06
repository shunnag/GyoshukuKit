import Foundation

// 名前の正規化・衝突検査・ディスク探索は ArchiveWriter と共有する。
final class LHAWriter {
    private typealias Method = LHARecords.Method
    private let output: FileHandle
    private let url: URL
    private var finished = false
    private var aborted = false
    static let compressionChunkSize = 1 * 1024 * 1024
    private let threads: Int
    private let configuration: LH5Encoder.Configuration
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
    // 書いた member の位置と長さを memberRecords に残す。LHA の更新が自己検査に使う。
    private let recordsMembers: Bool
    private(set) var memberRecords: [MemberRecord] = []

    init(output: FileHandle, url: URL, threads: Int = 1,
         method: LHACompressionMethod = .lh5, level: Int = 6, recordsMembers: Bool = false,
         encoder: (@Sendable (Data) throws -> Data)? = nil) {
        precondition((1...64).contains(threads))
        let configuration = LH5Encoder.Configuration(method: method, level: level)
        let encoder: @Sendable (Data) throws -> Data = encoder ?? { try LH5Encoder.encode($0, configuration: configuration) }
        self.output = output
        self.url = url
        self.threads = threads
        self.configuration = configuration
        self.recordsMembers = recordsMembers
        self.encoder = encoder
        pipeline = threads > 1 && method != .stored ? OrderedChunkPipeline(threads: threads) { input in
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
        if configuration.method == .stored {
            try addStored(entry: entry, name: name, size: size, read: read)
            return
        }
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
            let requested = Int(min(UInt64(IOChunk.size), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            input.append(chunk)
            crc = LHACRC16.update(crc, chunk)
            remaining -= UInt64(chunk.count)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if let pipeline {
            let directory = mode.isDirectoryMode
            try pipeline.submit(directory ? nil : input,
                tag: Pending(entry: entry, crc: crc, input: input, directory: directory), weight: UInt64(input.count), emit: emit)
            return
        }
        let compressed = try encoder(input)
        let shrinks = compressed.count < input.count
        let payload = shrinks ? compressed : input
        let method = mode.isDirectoryMode ? Method.lhd : shrinks ? configuration.method.headerMethod : Method.lh0
        try writeMember(entry, method: method, payload: payload, crc: crc)
        try Task.checkCancellation()
    }

    private func emit(_ pending: Pending, _ result: Data??) throws {
        let compressed = result ?? nil
        let method = pending.directory ? Method.lhd : compressed == nil ? Method.lh0 : configuration.method.headerMethod
        try writeMember(pending.entry, method: method, payload: compressed ?? pending.input, crc: pending.crc)
    }

    /// forced store は圧縮用 spool・辞書・member 全体の入力を作らず、CRC だけを確定して header を戻す。
    private func addStored(entry: LHARecords.Entry, name: String, size: UInt64,
                           read: (Int) throws -> Data) throws {
        let offset = try output.offset()
        let method = entry.mode.isDirectoryMode ? Method.lhd : Method.lh0
        let placeholder = try entry.header(method: method, packedSize: entry.size, crc: 0)
        try write(placeholder)
        var remaining = size
        var crc: UInt16 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(IOChunk.size), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            try write(chunk)
            crc = LHACRC16.update(crc, chunk)
            remaining -= UInt64(chunk.count)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        let end = try output.offset()
        try output.seek(toOffset: offset)
        try write(entry.header(method: method, packedSize: entry.size, crc: crc))
        try output.seek(toOffset: end)
        record(entry, offset: offset, headerLength: placeholder.count, dataLength: size, method: method)
        try Task.checkCancellation()
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

    /// 1 MiB を超える member。仮 header を書いてから raw byte を出力へ、圧縮 byte を spool へ書き進め、
    /// 最後に縮んだ側を残して header を確定する。addStreamed（逐次）と addStreamedParallel（並列）が共有する。
    /// 圧縮 byte は名前を残さない ScratchFile に保存し、member を書き終えると閉じる。
    private struct StreamedMember {
        let writer: LHAWriter
        let entry: LHARecords.Entry
        let name: String
        let size: UInt64
        let headerOffset: UInt64
        let placeholder: Data
        let spool: ScratchFile
        let payloadOffset: UInt64
        private(set) var remaining: UInt64
        private(set) var crc: UInt16 = 0

        init(writer: LHAWriter, entry: LHARecords.Entry, name: String, size: UInt64) throws {
            self.writer = writer; self.entry = entry; self.name = name; self.size = size
            headerOffset = try writer.output.offset()
            placeholder = try entry.header(method: Method.lh0, packedSize: entry.size, crc: 0)
            spool = try ScratchFile(directory: writer.url.deletingLastPathComponent(), tag: "lha", pathExtension: writer.url.pathExtension)
            try writer.write(placeholder)
            payloadOffset = try writer.output.offset()
            remaining = size
        }

        /// history に続けて最大 compressionChunkSize を IOChunk.size ずつ読み、raw を出力へ書きつつ CRC を進める。
        mutating func readChunk(after history: Data, read: (Int) throws -> Data) throws -> Data {
            var input = history
            let target = history.count + Int(min(UInt64(LHAWriter.compressionChunkSize), remaining))
            input.reserveCapacity(target)
            while input.count < target {
                try Task.checkCancellation()
                let requested = min(IOChunk.size, target - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                try writer.write(chunk)
                crc = LHACRC16.update(crc, chunk)
                input.append(chunk)
                remaining -= UInt64(chunk.count)
            }
            return input
        }

        /// 圧縮を続けていれば残りの bit を spool へ流し、縮んだなら spool を payload の位置へ戻して切り詰める。
        /// 確定した header を仮 header の位置に書き、record する。
        func finish(compressing: Bool, bits: inout LH5Encoder.Bits) throws {
            if compressing { try spool.append(bits.finish()) }
            let shrinks = compressing && spool.length < size
            let packedSize = shrinks ? spool.length : size
            let end = try checkedAdd(payloadOffset, packedSize)
            if shrinks {
                try writer.output.seek(toOffset: payloadOffset)
                try spool.forEachChunk(writer.write)
                try writer.output.truncate(atOffset: end)
            }
            let method = shrinks ? writer.configuration.method.headerMethod : Method.lh0
            let header = try entry.header(method: method, packedSize: UInt32(packedSize), crc: crc)
            guard header.count == placeholder.count else { throw WriterError.invalidState }
            try writer.output.seek(toOffset: headerOffset)
            try writer.write(header)
            try writer.output.seek(toOffset: end)
            writer.record(entry, offset: headerOffset, headerLength: header.count, dataLength: packedSize, method: method)
            try Task.checkCancellation()
        }
    }

    private func addStreamed(entry: LHARecords.Entry, name: String, size: UInt64,
                             read: (Int) throws -> Data) throws {
        var member = try StreamedMember(writer: self, entry: entry, name: name, size: size)
        var bits = LH5Encoder.Bits()
        var compressing = true
        var history = Data()
        while member.remaining > 0 {
            try Task.checkCancellation()
            let prefixSize = history.count
            let input = try member.readChunk(after: history, read: read)
            if compressing {
                try LH5Encoder.write(input, startingAt: prefixSize, configuration: configuration, to: &bits)
                history = Data(input.suffix(configuration.windowSize))
                try member.spool.append(bits.takeCompleteBytes())
                // 圧縮出力は増えるだけ。勝てないと分かった時点で、既に書いた raw byte を残して codec の仕事を止める。
                compressing = member.spool.length < size
            }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        try member.finish(compressing: compressing, bits: &bits)
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
        var member = try StreamedMember(writer: self, entry: entry, name: name, size: size)
        let spool = member.spool
        let configuration = self.configuration
        let pieces = OrderedChunkPipeline<Piece, PieceOutput, Void>(threads: threads) { piece in
            var bits = LH5Encoder.Bits()
            try LH5Encoder.write(piece.input, startingAt: piece.prefix, configuration: configuration, to: &bits)
            let remainder = bits.remainder
            return PieceOutput(bytes: bits.takeCompleteBytes(), remainder: remainder)
        }
        var bits = LH5Encoder.Bits()
        var history = Data()
        var compressing = true
        func emitPiece(_: Void, _ result: PieceOutput?) throws {
            guard let result else { throw WriterError.invalidState }
            bits.append(result.bytes, remainder: result.remainder)
            try spool.append(bits.takeCompleteBytes())
            // emit 中に直接 abandon すると、pipeline の取出し途中の tag を消してしまう。
            // 内部の停止だけを捕捉し、pipeline 自身の失敗時の abandon を通す。
            if spool.length >= size { throw CompressionStopped.stored }
        }
        while member.remaining > 0 {
            try Task.checkCancellation()
            if compressing {
                do { try pieces.waitForCapacity(emit: emitPiece) }
                catch CompressionStopped.stored { compressing = false; history = Data() }
            }
            let prefixSize = history.count
            let input = try member.readChunk(after: history, read: read)
            if compressing {
                history = Data(input.suffix(configuration.windowSize))
                try pieces.submit(Piece(input: input, prefix: prefixSize), tag: (), emit: emitPiece)
            }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if compressing {
            do { try pieces.finish(emit: emitPiece) }
            catch CompressionStopped.stored { compressing = false }
        }
        try member.finish(compressing: compressing, bits: &bits)
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
        for offset in stride(from: 0, to: data.count, by: IOChunk.size) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            try output.write(contentsOf: data[start..<min(start + IOChunk.size, data.endIndex)])
        }
    }
}
