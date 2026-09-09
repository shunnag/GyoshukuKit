import Foundation
private import Darwin

/// ZIP / ZIP64 を新規作成する。既存の出力先は上書きしない。
///
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
/// finish() が成功して初めて書庫が完成する。deinit は自動 finish しない。
/// add / finish が失敗した instance は再利用できず、部分出力は呼出側で削除する。
public final class ArchiveWriter {
    public let format: ArchiveFormat
    private let options: WriterOptions
    private let output: FileHandle
    private let outputIdentity: (dev_t, ino_t)
    private var position: UInt64 = 0
    private var entries: [ZipRecords.Entry] = []
    private var names: Set<String> = []
    private var files: Set<String> = []
    private var requiredDirectories: Set<String> = []
    private enum State { case writing, finished, failed }
    private var state = State.writing
    private static let chunkSize = 256 * 1024

    private init(output: FileHandle, identity: (dev_t, ino_t), format: ArchiveFormat, options: WriterOptions) {
        self.output = output
        self.outputIdentity = identity
        self.format = format
        self.options = options
    }

    deinit { try? output.close() }

    /// options を検証してから O_EXCL で出力を新規作成する。
    public static func create(
        url: URL, format: ArchiveFormat = .zip, options: WriterOptions = WriterOptions()
    ) throws -> ArchiveWriter {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
        guard (0...9).contains(options.deflateLevel) else { throw WriterError.invalidOption("deflateLevel") }
        guard !options.preserveMacOSMetadata else { throw WriterError.unsupportedOption("preserveMacOSMetadata") }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666) } ?? -1
        }
        guard fd >= 0 else { throw WriterError.io(operation: "create", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
        return ArchiveWriter(output: handle, identity: (info.st_dev, info.st_ino), format: format, options: options)
    }

    /// ディレクトリは名前順で再帰追加する。symlink は辿らず target path を保存する。
    public func add(contentsOf url: URL, as path: String) throws {
        try perform { try addDisk(url, as: path) }
    }

    /// 明示的な空ディレクトリ。mode は 0755、mtime は現在時刻。
    public func addDirectory(_ path: String) throws {
        try perform {
            try addEntry(path: path, mode: 0o40755, size: 0, date: Date(), atime: nil, owners: nil) { _ in Data() }
        }
    }

    /// メモリ上の内容を追加する。mode の既定は 0644。日付は秒単位に切り捨てる。
    /// extended timestamp の符号付き 32 bit 秒に収まらない日付は拒否する。
    public func add(
        data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil
    ) throws {
        try perform {
            var offset = 0
            try addEntry(
                path: path, mode: 0o100000 | ((permissions ?? 0o644) & 0o7777), size: UInt64(data.count),
                date: modificationDate ?? Date(), atime: nil, owners: nil
            ) { requested in
                let count = min(requested, data.count - offset)
                defer { offset += count }
                return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
            }
        }
    }

    /// central directory と終端 record を書き、出力を閉じる。成功後の再呼出しは何もしない。
    public func finish() throws {
        if state == .finished { return }
        try perform {
            let start = position
            for entry in entries { try write(entry.central()) }
            try write(ZipRecords.end(count: UInt64(entries.count), centralSize: position - start, centralOffset: start))
            try output.synchronize()
            try output.close()
            state = .finished
        }
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .writing else { throw WriterError.invalidState }
        do { try body() } catch {
            state = .failed
            try? output.close()
            throw error
        }
    }

    private func addDisk(_ url: URL, as path: String) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { lstat($0, &info) } ?? -1
        }
        guard status == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
        guard info.st_dev != outputIdentity.0 || info.st_ino != outputIdentity.1 else {
            throw WriterError.invalidPath("source contains output archive")
        }
        let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        let atime = Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec))
        let owners = options.preserveOwnerIDs ? (info.st_uid, info.st_gid) : nil
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try addEntry(path: path, mode: UInt16(info.st_mode), size: 0, date: date, atime: atime, owners: owners) { _ in Data() }
            let base = path.hasSuffix("/") ? String(path.dropLast()) : path
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try addDisk(child, as: base + "/" + child.lastPathComponent)
            }
        case S_IFLNK:
            // readlink は NUL を付けない。target を UTF-8 へ再符号化せず byte のまま保存する。
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = url.withUnsafeFileSystemRepresentation { pointer in
                pointer.map { readlink($0, &buffer, buffer.count) } ?? -1
            }
            guard count >= 0 else { throw WriterError.io(operation: "readlink", code: errno) }
            guard count < buffer.count else { throw WriterError.sourceChanged(url.path) }
            var payload = Data(buffer.prefix(count))
            try addEntry(path: path, mode: 0xA1ED, size: UInt64(count), date: date, atime: atime, owners: owners) { _ in
                defer { payload = Data() }
                return payload
            }
        case S_IFREG:
            // lstat と open の間に symlink へ置換されても辿らない。
            let fd = url.withUnsafeFileSystemRepresentation { pointer in
                pointer.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
            }
            guard fd >= 0 else { throw WriterError.io(operation: "open source", code: errno) }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw WriterError.io(operation: "fstat source", code: errno) }
            guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
                  opened.st_mode & S_IFMT == S_IFREG, opened.st_size == info.st_size, info.st_size >= 0 else {
                throw WriterError.sourceChanged(url.path)
            }
            try addEntry(path: path, mode: UInt16(info.st_mode), size: UInt64(info.st_size), date: date, atime: atime, owners: owners) {
                try input.read(upToCount: $0) ?? Data()
            }
            var after = stat()
            guard fstat(fd, &after) == 0 else { throw WriterError.io(operation: "fstat after read", code: errno) }
            guard after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                throw WriterError.sourceChanged(url.path)
            }
        default:
            throw WriterError.unsupportedFileType(url.path)
        }
    }

    private func addEntry(
        path: String, mode: UInt16, size: UInt64, date: Date, atime: Date?, owners: (UInt32, UInt32)?,
        read: (Int) throws -> Data
    ) throws {
        let directory = mode & 0xF000 == 0x4000
        let name = try normalizedPath(path, directory: directory)
        let key = directory ? String(name.dropLast()) : name
        guard names.insert(key).inserted else {
            throw WriterError.duplicatePath(name)
        }
        // file とその子を同居させない。後から親 directory を明示追加することは許す。
        guard directory || !requiredDirectories.contains(key) else { throw WriterError.invalidPath(name) }
        var prefix = ""
        for component in key.split(separator: "/").dropLast() {
            prefix += prefix.isEmpty ? String(component) : "/" + component
            guard !files.contains(prefix) else { throw WriterError.invalidPath(name) }
            requiredDirectories.insert(prefix)
        }
        if !directory { files.insert(key) }
        let method = compression(name: name, mode: mode, size: size)
        let mtime = try ZipRecords.timestamp(date)
        let accessTime = try ZipRecords.timestamp(atime ?? date)
        let dos = ZipRecords.dosDate(date)
        var entry = ZipRecords.Entry(
            name: Data(name.utf8), method: method, mtime: mtime,
            atime: accessTime, dosTime: dos.time, dosDate: dos.date,
            mode: mode, owners: owners, offset: position, size: size
        )
        // zlib compressBound の保守的上限。境界付近でも header の領域を後から増やさない。
        var bound = size
        if method == .deflate {
            for extra in [size >> 12, size >> 14, size >> 25, 13] { bound = try checkedAdd(bound, extra) }
        }
        entry.reservedZIP64 = bound >= ZipRecords.limit
        let header = entry.local()
        try write(header)
        let start = position
        let compressor = method == .deflate ? try DeflateCompressor(level: options.deflateLevel) : nil
        var remaining = size
        while remaining > 0 {
            let requested = Int(min(UInt64(Self.chunkSize), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            entry.crc = updateCRC(entry.crc, chunk)
            remaining -= UInt64(chunk.count)
            if let compressor { try compressor.write(chunk, emit: write) } else { try write(chunk) }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if let compressor { try compressor.write(Data(), finish: true, emit: write) }
        entry.compressedSize = position - start
        let patched = entry.local()
        guard patched.count == header.count else { throw WriterError.sizeOverflow }
        try output.seek(toOffset: entry.offset)
        try output.write(contentsOf: patched)
        try output.seek(toOffset: position)
        entries.append(entry)
    }

    private func write(_ data: Data) throws {
        let next = try checkedAdd(position, UInt64(data.count))
        try output.write(contentsOf: data)
        position = next
    }

    private func compression(name: String, mode: UInt16, size: UInt64) -> CompressionMethod {
        guard size > 0, mode & 0xF000 == 0x8000 else { return .stored }
        if options.useCompressionHeuristic {
            let compressed: Set<String> = ["zip", "gz", "bz2", "xz", "7z", "rar", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp3", "mp4", "mov", "pdf"]
            if compressed.contains((name as NSString).pathExtension.lowercased()) { return .stored }
        }
        return options.compressionMethod
    }

    private func normalizedPath(_ path: String, directory: Bool) throws -> String {
        var name = path.precomposedStringWithCanonicalMapping
        if directory && !name.hasSuffix("/") { name += "/" }
        let body = directory ? String(name.dropLast()) : name
        let components = body.split(separator: "/", omittingEmptySubsequences: false)
        guard !body.isEmpty, !body.contains("\0"), !body.contains("\\"), !body.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.count <= Int(UInt16.max) else { throw WriterError.invalidPath(path) }
        return name
    }
}
