import Foundation
private import Darwin

final class SevenZipWriter {
    private let output: FileHandle
    private let url: URL
    private let identity: (dev_t, ino_t)
    private var entries: [SevenZipRecords.Entry] = []
    private var position: UInt64 = 0
    private var finished = false
    private var aborted = false
    private static let chunkSize = 256 * 1024

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t)) {
        self.output = output
        self.url = url
        self.identity = identity
    }

    deinit { abort() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        var entry = SevenZipRecords.Entry(name: name, mode: mode, size: size,
                                           mtime: try SevenZipRecords.timestamp(date))
        guard size <= UInt64(Int.max) else { throw WriterError.sizeOverflow }
        try reserveSignature()
        // Apple の buffer API はファイル全体を必要とする。non-solid なので保持は一ファイル分で済む。
        var input = Data()
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(Self.chunkSize), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            input.append(chunk)
            entry.crc = updateCRC(entry.crc, chunk)
            remaining -= UInt64(chunk.count)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if size > 0 {
            let compressed = try LZMA2Compressor.encode(input)
            entry.properties = compressed.properties
            entry.packedSize = UInt64(compressed.payload.count)
            try write(compressed.payload)
        }
        try Task.checkCancellation()
        entries.append(entry)
    }

    func finish() throws {
        try Task.checkCancellation()
        try reserveSignature()
        let packedSize = position - 32
        let header = try SevenZipRecords.header(entries)
        try write(header)
        try output.synchronize()
        try Task.checkCancellation()
        let signature = SevenZipRecords.signature(packedSize: packedSize, header: header)
        try Task.checkCancellation()
        // payload と plain header が揃ってから署名を確定する。失敗時は hard link 側も含めて無効化する。
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
