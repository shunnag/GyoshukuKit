import Foundation
private import Darwin

final class SevenZipWriter {
    private let output: FileHandle
    private let url: URL
    private let identity: (dev_t, ino_t)
    private let options: WriterOptions
    private var encryptionKey: Data?
    private var entries: [SevenZipRecords.Entry] = []
    private var position: UInt64 = 0
    private var finished = false
    private var aborted = false
    private static let chunkSize = 256 * 1024
    private static let lzmaChunkSize = 16 * 1024 * 1024

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t), options: WriterOptions) {
        self.output = output
        self.url = url
        self.identity = identity
        self.options = options
    }

    deinit { abort() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        var entry = SevenZipRecords.Entry(name: name, mode: mode, size: size,
                                           mtime: try SevenZipRecords.timestamp(date))
        try reserveSignature()
        let aes = size > 0 ? try makeEncryptor() : nil
        entry.aesProperties = aes?.properties
        let start = position
        func emit(_ data: Data) throws {
            entry.compressedSize = try checkedAdd(entry.compressedSize, UInt64(data.count))
            for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
                try Task.checkCancellation()
                let start = data.startIndex + offset
                let chunk = data.subdata(in: start..<min(start + Self.chunkSize, data.endIndex))
                try write(aes.map { try $0.encrypt(chunk) } ?? chunk)
            }
        }
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let inputSize = Int(min(UInt64(Self.lzmaChunkSize), remaining))
            var input = Data()
            input.reserveCapacity(inputSize)
            // 短い read でも圧縮境界を変えず、I/O だけを 256 KiB に保つ。
            while input.count < inputSize {
                try Task.checkCancellation()
                let requested = min(Self.chunkSize, inputSize - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                entry.crc = updateCRC(entry.crc, chunk)
                remaining -= UInt64(chunk.count)
                input.append(chunk)
            }
            // Apple の 8 MiB 辞書を活かし、buffer API の入力は最大 16 MiB にする。各片の reset は維持し、
            // LZMA2 終端だけを除いて一つの stream に連結する（最後に一度だけ終端を書く）。
            let compressed = try LZMA2Compressor.encode(input)
            guard let control = compressed.payload.first, control == 1 || control >= 0xE0,
                  compressed.payload.last == 0 else { throw WriterError.compression(-1) }
            entry.properties = max(entry.properties, compressed.properties)
            try emit(Data(compressed.payload.dropLast()))
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if size > 0 {
            try emit(Data([0]))
            if let aes { try write(aes.finish()) }
            entry.packedSize = position - start
        }
        try Task.checkCancellation()
        entries.append(entry)
    }

    func finish() throws {
        try Task.checkCancellation()
        try reserveSignature()
        var packedSize = position - 32
        var header = try SevenZipRecords.header(entries)
        if options.encryptsSevenZipHeaders {
            guard let aes = try makeEncryptor() else { throw WriterError.invalidOption("encryptsSevenZipHeaders") }
            let plainSize = UInt64(header.count)
            let crc = SevenZipRecords.checksum(header)
            let start = position
            for offset in stride(from: 0, to: header.count, by: Self.chunkSize) {
                try Task.checkCancellation()
                try write(aes.encrypt(header.subdata(in: offset..<min(offset + Self.chunkSize, header.count))))
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
        try? output.truncate(atOffset: 0)
        // 出力先が置換されていても別の inode を削除しない。旧 inode の別名は truncate で無効になる。
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            var current = stat()
            if lstat(path, &current) == 0, current.st_dev == identity.0, current.st_ino == identity.1 {
                _ = unlink(path)
            }
        }
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

    private func write(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            let chunk = data.subdata(in: start..<min(start + Self.chunkSize, data.endIndex))
            let next = try checkedAdd(position, UInt64(chunk.count))
            try output.write(contentsOf: chunk)
            position = next
        }
    }
}
