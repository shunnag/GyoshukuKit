import Foundation
private import Darwin

final class SevenZipWriter {
    private let output: FileHandle
    private let url: URL
    private let options: WriterOptions
    private var encryptionKey: Data?
    private var entries: [SevenZipRecords.Entry] = []
    private var position: UInt64 = 0
    private var finished = false
    private var aborted = false
    private static let chunkSize = 256 * 1024
    private let lzmaChunkSize: Int
    private let pipeline: LZMA2ChunkPipeline<ChunkTag>

    private final class PendingEntry {
        var record: SevenZipRecords.Entry
        let aes: SevenZipAESEncryptor?
        var start: UInt64?

        init(record: SevenZipRecords.Entry, aes: SevenZipAESEncryptor?) {
            self.record = record
            self.aes = aes
            self.record.aesProperties = aes?.properties
        }
    }

    private struct ChunkTag {
        let entry: PendingEntry
        let isLast: Bool
    }

    init(output: FileHandle, url: URL, identity _: (dev_t, ino_t), options: WriterOptions,
         chunkSize: Int = LZMA2ChunkPipeline<Void>.chunkSize,
         encoder: @escaping LZMA2ChunkPipeline<Void>.Encoder = LZMA2Compressor.encode) {
        precondition((1...LZMA2ChunkPipeline<Void>.chunkSize).contains(chunkSize))
        self.output = output
        self.url = url
        self.options = options
        lzmaChunkSize = chunkSize
        pipeline = LZMA2ChunkPipeline(threads: options.resolvedCompressionThreads, encoder: encoder)
    }

    deinit { abort() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        let record = SevenZipRecords.Entry(name: name, mode: mode, size: size,
                                           mtime: try SevenZipRecords.timestamp(date))
        try reserveSignature()
        let entry = PendingEntry(record: record, aes: size > 0 ? try makeEncryptor() : nil)
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let inputSize = Int(min(UInt64(lzmaChunkSize), remaining))
            var input = Data()
            input.reserveCapacity(inputSize)
            // 短い read でも圧縮境界を変えず、I/O だけを 256 KiB に保つ。
            while input.count < inputSize {
                try Task.checkCancellation()
                let requested = min(Self.chunkSize, inputSize - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                entry.record.crc = updateCRC(entry.record.crc, chunk)
                remaining -= UInt64(chunk.count)
                input.append(chunk)
            }
            if remaining == 0 {
                guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            }
            try pipeline.submit(input, tag: ChunkTag(entry: entry, isLast: remaining == 0), emit: emit)
        }
        if size == 0 {
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            try pipeline.submit(nil, tag: ChunkTag(entry: entry, isLast: true), emit: emit)
        }
        try Task.checkCancellation()
    }

    func finish() throws {
        try Task.checkCancellation()
        try reserveSignature()
        try pipeline.finish(emit: emit)
        var packedSize = position - 32
        var header = try SevenZipRecords.header(entries)
        if options.encryptsSevenZipHeaders {
            guard let aes = try makeEncryptor() else { throw WriterError.invalidOption("encryptsSevenZipHeaders") }
            let plainSize = UInt64(header.count)
            let crc = SevenZipRecords.checksum(header)
            let start = position
            for offset in stride(from: 0, to: header.count, by: Self.chunkSize) {
                try Task.checkCancellation()
                try write(aes.encrypt(header[offset..<min(offset + Self.chunkSize, header.count)]))
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

    private func makeEncryptor() throws -> SevenZipAESEncryptor? {
        guard let password = options.password else { return nil }
        // salt なしの KDF は書庫内で共通。各 folder / header の IV は毎回独立に生成する。
        if encryptionKey == nil { encryptionKey = try EncryptionPrimitives.sevenZipKey(password: password) }
        return try SevenZipAESEncryptor(key: encryptionKey!)
    }

    private func emit(_ tag: ChunkTag, _ result: LZMA2ChunkPipeline<ChunkTag>.Output?) throws {
        try Task.checkCancellation()
        let entry = tag.entry
        if entry.start == nil { entry.start = position }
        if let compressed = result?.compressed {
            // 各片の辞書 reset を維持し、LZMA2 終端は entry の最後に一度だけ置く。
            guard let control = compressed.payload.first, control == 1 || control >= 0xE0,
                  compressed.payload.last == 0 else { throw WriterError.compression(-1) }
            entry.record.properties = max(entry.record.properties, compressed.properties)
            try emit(compressed.payload.dropLast(), to: entry)
        }
        if tag.isLast {
            if entry.record.size > 0 {
                try emit(Data([0]), to: entry)
                if let aes = entry.aes { try write(aes.finish()) }
                entry.record.packedSize = position - entry.start!
            }
            entries.append(entry.record)
        }
    }

    private func emit(_ data: Data, to entry: PendingEntry) throws {
        entry.record.compressedSize = try checkedAdd(entry.record.compressedSize, UInt64(data.count))
        for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            let chunk = data[start..<min(start + Self.chunkSize, data.endIndex)]
            try write(entry.aes.map { try $0.encrypt(chunk) } ?? chunk)
        }
    }

    private func write(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            let chunk = data[start..<min(start + Self.chunkSize, data.endIndex)]
            let next = try checkedAdd(position, UInt64(chunk.count))
            try output.write(contentsOf: chunk)
            position = next
        }
    }
}
