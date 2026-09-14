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

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t)) {
        self.output = output
        self.url = url
        self.identity = identity
    }

    deinit { abort() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        let entry = try LHARecords.Entry(name: name, mode: mode, size: size, date: date)
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
