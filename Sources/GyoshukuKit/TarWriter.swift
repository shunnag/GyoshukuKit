import Foundation
private import Darwin

// 名前の検証・衝突検査・ディスク探索は ArchiveWriter と共有し、ここでは tar だけを扱う。
final class TarWriter {
    private let output: FileHandle
    private let url: URL
    private let identity: (dev_t, ino_t)
    private let gzip: GzipCompressor?
    private var position: UInt64 = 0
    private var finished = false
    private var aborted = false
    private struct FileID: Hashable { let device: Int64; let inode: UInt64 }
    private var hardLinks: [FileID: (path: String, signature: [Int64])] = [:]

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t), gzip: GzipCompressor?) {
        self.output = output
        self.url = url
        self.identity = identity
        self.gzip = gzip
    }

    deinit { abort() }

    func hardLinkTarget(device: Int64, inode: UInt64, signature: [Int64]) throws -> String? {
        guard let previous = hardLinks[FileID(device: device, inode: inode)] else { return nil }
        guard previous.signature == signature else { throw WriterError.sourceChanged(previous.path) }
        return previous.path
    }

    func rememberHardLink(device: Int64, inode: UInt64, signature: [Int64], path: String) {
        hardLinks[FileID(device: device, inode: inode)] = (path, signature)
    }

    func add(
        name: String, mode: UInt16, size: UInt64, date: Date, owners: (UInt32, UInt32)?,
        hardLink: String?, read: (Int) throws -> Data
    ) throws {
        try Task.checkCancellation()
        var entry = TarRecords.Entry(name: Data(name.utf8), mode: mode, size: size,
                                     mtime: try TarRecords.timestamp(date), uid: owners?.0 ?? 0, gid: owners?.1 ?? 0)
        if mode & 0xF000 == 0x4000 {
            entry.type = 0x35
            entry.size = 0
        } else if mode & 0xF000 == 0xA000 {
            // link は payload ではない。readlink 由来の byte をそのまま linkname / pax に置く。
            guard size <= UInt64(PATH_MAX) else { throw WriterError.invalidPath(name) }
            entry.link = try read(Int(size))
            guard entry.link.count == Int(size), !entry.link.contains(0), try read(1).isEmpty else {
                throw WriterError.sourceChanged(name)
            }
            entry.type = 0x32
            entry.size = 0
        } else if let hardLink {
            entry.type = 0x31
            entry.link = Data(hardLink.utf8)
            entry.size = 0
        }
        try write(entry.headers())
        if entry.type == 0x30 {
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = Int(min(256 * 1024, remaining))
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                try write(chunk)
                remaining -= UInt64(chunk.count)
            }
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            try write(Data(count: TarRecords.padding(size)))
        }
    }

    func finish() throws {
        try Task.checkCancellation()
        // 終端の二 block を必ず置き、その後を従来の blocking factor 20 までゼロで埋める。
        try write(Data(count: 2 * TarRecords.blockSize))
        let padding = (UInt64(TarRecords.recordSize) - position % UInt64(TarRecords.recordSize)) % UInt64(TarRecords.recordSize)
        try write(Data(count: Int(padding)))
        if let gzip { try gzip.write(Data(), finish: true, emit: emit) }
        try Task.checkCancellation()
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()
        finished = true
    }

    func abort() {
        guard !finished, !aborted else { return }
        aborted = true
        // tar は途中まででも読めるため、失敗時には終端を省くだけでは不十分。
        // 別名の hard link も無効化し、出力先が置換されていれば別人のファイルは消さない。
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
        try Task.checkCancellation()
        let next = try checkedAdd(position, UInt64(data.count))
        if let gzip { try gzip.write(data, emit: emit) } else { try emit(data) }
        position = next
    }

    private func emit(_ data: Data) throws {
        try Task.checkCancellation()
        try output.write(contentsOf: data)
    }
}
