import Foundation
private import Darwin

final class SevenZipWriter {
    private let output: FileHandle
    private let url: URL
    private let options: WriterOptions
    private var encryptors: SevenZipAESEncryptor.Factory
    struct AppendedEntry {
        let record: SevenZipRecords.Entry
        let packRange: Range<UInt64>
    }
    private var entries: [SevenZipRecords.Entry] = []
    private var appendedEntries: [AppendedEntry] = []
    private let isAppend: Bool
    private var position: UInt64 = 0
    private var finished = false
    private var aborted = false
    private let pipeline: SevenZipChunkPipeline<ChunkTag>

    private final class PendingEntry {
        var record: SevenZipRecords.Entry
        let encoder: SevenZipFolderEncoder
        var start: UInt64?

        init(record: SevenZipRecords.Entry, aes: SevenZipAESEncryptor?, options: WriterOptions) throws {
            self.record = record
            encoder = SevenZipFolderEncoder(aes: aes, method: options.sevenZipMethod,
                deflateLevel: options.deflateLevel, bzip2Level: options.bzip2Level,
                lzma: options.sevenZipMethod == .lzma || options.sevenZipMethod == .lzma2
                    ? try LZMAWriterConfiguration(options: options, raw: options.sevenZipMethod == .lzma) : nil,
                size: record.size)
            self.record.method = options.sevenZipMethod
            self.record.lzmaProperties = encoder.lzmaProperties
            self.record.aesProperties = aes?.properties
        }
    }

    private struct ChunkTag {
        let entry: PendingEntry
        let isLast: Bool
    }

    init(output: FileHandle, url: URL, options: WriterOptions,
         startPosition: UInt64? = nil, chunkSize: Int? = nil,
         encoder: LZMA2ChunkPipeline<Void>.Encoder? = nil) throws {
        self.output = output
        self.url = url
        self.options = options
        encryptors = SevenZipAESEncryptor.Factory(password: options.password)
        isAppend = startPosition != nil
        position = startPosition ?? 0
        pipeline = try SevenZipChunkPipeline(options: options, chunkSize: chunkSize, encoder: encoder)
    }

    deinit { abort() }

    var pendingInputBytes: UInt64 { pipeline.pendingInputBytes }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?) throws {
        try pipeline.drain(didEmit: didEmit, emit: emit)
    }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        let record = SevenZipRecords.Entry(name: name, mode: mode, size: size,
                                           mtime: try SevenZipRecords.timestamp(date))
        try reserveSignature()
        let entry = try PendingEntry(record: record, aes: size > 0 ? try encryptors.make() : nil, options: options)
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let inputSize = Int(min(UInt64(pipeline.chunkSize), remaining))
            var input = Data()
            input.reserveCapacity(inputSize)
            // 短い read でも圧縮境界を変えず、I/O だけを 256 KiB に保つ。
            while input.count < inputSize {
                try Task.checkCancellation()
                let requested = min(IOChunk.size, inputSize - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                entry.record.crc = updateCRC(entry.record.crc, chunk)
                remaining -= UInt64(chunk.count)
                input.append(chunk)
            }
            if remaining == 0 {
                guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            }
            try pipeline.submit(input, tag: ChunkTag(entry: entry, isLast: remaining == 0), isLast: remaining == 0,
                                weight: UInt64(input.count), emit: emit)
        }
        if size == 0 {
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            try pipeline.submit(nil, tag: ChunkTag(entry: entry, isLast: true), isLast: true, emit: emit)
        }
        try Task.checkCancellation()
    }

    // 検証済みの単一 chunk は、読み直し・コピー・CRC の再計算をせず既存の encoder へ渡す。
    func add(name: String, mode: UInt16, date: Date, prefetched: Prefetched) throws {
        let data = prefetched.data
        guard data.count <= pipeline.chunkSize else {
            var offset = data.startIndex
            try add(name: name, mode: mode, size: UInt64(data.count), date: date) { count in
                let end = min(offset + count, data.endIndex)
                defer { offset = end }
                return data[offset..<end]
            }
            return
        }
        try Task.checkCancellation()
        var record = SevenZipRecords.Entry(name: name, mode: mode, size: UInt64(data.count),
                                           mtime: try SevenZipRecords.timestamp(date))
        record.crc = prefetched.crc
        try reserveSignature()
        let entry = try PendingEntry(record: record, aes: data.isEmpty ? nil : try encryptors.make(), options: options)
        try pipeline.submit(data.isEmpty ? nil : data, tag: ChunkTag(entry: entry, isLast: true),
                            isLast: true, weight: UInt64(data.count), emit: emit)
        try Task.checkCancellation()
    }

    func finish() throws {
        try Task.checkCancellation()
        try reserveSignature()
        try pipeline.finish(emit: emit)
        var packedSize = position - 32
        var header = try SevenZipRecords.header(entries)
        if options.encryptsSevenZipHeaders {
            guard let aes = try encryptors.make() else { throw WriterError.invalidOption("encryptsSevenZipHeaders") }
            let plainSize = UInt64(header.count)
            let crc = SevenZipRecords.checksum(header)
            let start = position
            for offset in stride(from: 0, to: header.count, by: IOChunk.size) {
                try Task.checkCancellation()
                try write(aes.encrypt(header[offset..<min(offset + IOChunk.size, header.count)]))
            }
            try write(aes.finish())
            header = SevenZipRecords.encodedHeader(packOffset: packedSize, packedSize: position - start,
                                                   unpackedSize: plainSize, crc: crc, properties: aes.properties)
            packedSize = position - 32
        }
        try write(header)
        try output.synchronize()
        try Task.checkCancellation()
        let signature = SevenZipRecords.signature(packedSize: packedSize, header: header)
        try Task.checkCancellation()
        // payload と header が揃ってから署名を確定する。失敗時は hard link 側も含めて無効化する。
        try output.seek(toOffset: 0)
        try output.write(contentsOf: signature)
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()
        finished = true
    }

    func abort() {
        guard !finished, !aborted else { return }
        aborted = true
        pipeline.abandon()
        // 出力先が置換されていても別の inode を削除しない。旧 inode の別名は truncate で無効になる。
        ArchiveOwnedFile.remove(url: url, descriptor: output.fileDescriptor)
        try? output.truncate(atOffset: 0)
    }

    private func reserveSignature() throws {
        if position == 0 { try write(Data(count: 32)) }
    }

    private func emit(_ tag: ChunkTag, _ result: SevenZipChunkOutput?) throws {
        try Task.checkCancellation()
        let entry = tag.entry
        if entry.start == nil { entry.start = position }
        if let result { try entry.encoder.consume(result, write: write) }
        if tag.isLast {
            if entry.record.size > 0 {
                try entry.encoder.finish(write: write)
                entry.record.properties = entry.encoder.properties
                entry.record.compressedSize = entry.encoder.compressedSize
                entry.record.packedSize = position - entry.start!
            }
            entries.append(entry.record)
            if isAppend { appendedEntries.append(AppendedEntry(record: entry.record, packRange: entry.start!..<position)) }
        }
    }

    func endEntries() throws -> [AppendedEntry] {
        guard !finished, !aborted, isAppend else { throw WriterError.invalidState }
        try Task.checkCancellation()
        try pipeline.finish(emit: emit)
        finished = true
        return appendedEntries
    }

    private func write(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: IOChunk.size) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            let chunk = data[start..<min(start + IOChunk.size, data.endIndex)]
            let next = try checkedAdd(position, UInt64(chunk.count))
            try output.write(contentsOf: chunk)
            if isAppend { ZipCopyEngine.writeObserver?(position, chunk.count) }
            position = next
        }
    }
}
