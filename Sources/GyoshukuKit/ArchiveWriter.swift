import Foundation
private import Darwin

/// ZIP / ZIP64、tar（gzip / bzip2 / XZ 圧縮を含む）、7z、LHA を新規作成する。既存の出力先は上書きしない。
///
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
/// finish() が成功して初めて書庫が完成する。deinit は自動 finish しない。
/// add / finish が失敗した instance は再利用できない。
/// ZIP の部分出力は呼出側で削除する。tar（圧縮tarを含む）/ 7z / LHA は失敗・未完了の破棄時に削除する。
public final class ArchiveWriter {
    public let format: ArchiveFormat
    private let options: WriterOptions
    private let output: FileHandle
    private let outputURL: URL
    // rewriter の失敗時も、出力先が別 inode に置換されていれば削除しない。
    let outputIdentity: (dev_t, ino_t)
    private let tarWriter: TarWriter?
    private let sevenZipWriter: SevenZipWriter?
    private let lhaWriter: LHAWriter?
    private var position: UInt64 = 0
    private var entries: [ZipRecords.Entry] = []
    private(set) var appendedPaths: [(String, Bool)] = []
    private var names: Set<String> = []
    private var files: Set<String> = []
    private var requiredDirectories: Set<String> = []
    private enum State { case writing, finished, failed }
    private var state = State.writing
    private static let chunkSize = 256 * 1024

    init(output: FileHandle, url: URL, identity: (dev_t, ino_t), format: ArchiveFormat, options: WriterOptions,
         tarWriter: TarWriter? = nil, sevenZipWriter: SevenZipWriter? = nil, lhaWriter: LHAWriter? = nil) {
        self.output = output
        self.outputURL = url
        self.outputIdentity = identity
        self.format = format
        self.options = options
        self.tarWriter = tarWriter
        self.sevenZipWriter = sevenZipWriter
        self.lhaWriter = lhaWriter
    }

    deinit {
        tarWriter?.abort()
        sevenZipWriter?.abort()
        lhaWriter?.abort()
        try? output.close()
    }

    /// create と同じ新規作成 API。既存書庫を更新する操作ではない。
    /// options を検証してから O_EXCL で出力を新規作成する。
    public static func create(
        url: URL, format: ArchiveFormat = .zip, options: WriterOptions = WriterOptions()
    ) throws -> ArchiveWriter {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
        try options.validate(for: format)
        if format != .zip { try Task.checkCancellation() }
        let compressor: (any TarCompressor)?
        switch format {
        case .tarGzip: compressor = try GzipCompressor(level: options.deflateLevel)
        case .tarBzip2: compressor = try Bzip2Compressor(level: options.bzip2Level)
        case .tarXZ: compressor = try XZCompressor()
        default: compressor = nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666) } ?? -1
        }
        guard fd >= 0 else { throw WriterError.io(operation: "create", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
        let identity = (info.st_dev, info.st_ino)
        let tar = format.isTar
            ? TarWriter(output: handle, url: url, identity: identity, compressor: compressor) : nil
        let sevenZip = format == .sevenZip
            ? SevenZipWriter(output: handle, url: url, identity: identity, options: options) : nil
        let lha = format == .lha ? LHAWriter(output: handle, url: url, identity: identity) : nil
        return ArchiveWriter(output: handle, url: url, identity: identity, format: format, options: options,
                             tarWriter: tar, sevenZipWriter: sevenZip, lhaWriter: lha)
    }

    /// ディレクトリは名前順で再帰追加する。symlink は辿らず target path を保存する。
    /// LHA は通常ファイルとディレクトリのみ対応し、symlink は拒否する。
    public func add(contentsOf url: URL, as path: String) throws {
        try add(contentsOf: url, as: path) { try $0.read(upToCount: $1) ?? Data() }
    }

    // 通常の source 読取と stat 検査を共有し、読取中の変更も決定的に検証できる。
    func add(contentsOf url: URL, as path: String, read: (FileHandle, Int) throws -> Data) throws {
        try perform { try addDisk(url, as: path, read: read) }
    }

    /// 明示的な空ディレクトリ。mode は 0755、mtime は現在時刻。
    public func addDirectory(_ path: String) throws {
        try perform {
            try addEntry(path: path, mode: 0o40755, size: 0, date: Date(), atime: nil, owners: nil) { _ in Data() }
        }
    }

    /// メモリ上の内容を追加する。mode の既定は 0644。日付は秒単位に切り捨てる。
    /// ZIP は符号付き 32 bit 秒、tar は符号付き 64 bit 秒に収まらない日付を拒否する。
    /// 7z は Windows FILETIME に収まらない日付を拒否する。
    /// LHA は符号なし 32 bit Unix 秒に収まらない日付と CP932 に往復できない名前を拒否する。
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

    // updater も同じ追加処理を使う。既存名は衝突検査にだけ使い、保存 byte は変更しない。
    func prepareAppend(at offset: UInt64, existingPaths: [(String, Bool)]) throws {
        try output.seek(toOffset: offset)
        position = offset
        replaceExistingPaths(existingPaths)
    }

    // 削除・改名を予約した後の add も、予約済みの名前集合で衝突を検査する。
    func replaceExistingPaths(_ paths: [(String, Bool)]) {
        names.removeAll(keepingCapacity: true)
        files.removeAll(keepingCapacity: true)
        requiredDirectories.removeAll(keepingCapacity: true)
        for (name, directory) in paths + appendedPaths {
            let key = name.hasSuffix("/") ? String(name.dropLast()) : name
            names.insert(key)
            if !directory { files.insert(key) }
            var prefix = ""
            for component in Self.pathComponents(key).dropLast() {
                prefix += prefix.isEmpty ? String(component) : "/" + component
                requiredDirectories.insert(prefix)
            }
        }
    }

    /// 形式ごとの終端 record を書き、出力を閉じる。成功後の再呼出しは何もしない。
    public func finish() throws {
        if let lhaWriter {
            if state == .finished { return }
            try perform {
                try lhaWriter.finish()
                state = .finished
            }
            return
        }
        if let sevenZipWriter {
            if state == .finished { return }
            try perform {
                try sevenZipWriter.finish()
                state = .finished
            }
            return
        }
        if let tarWriter {
            if state == .finished { return }
            try perform {
                try tarWriter.finish()
                state = .finished
            }
            return
        }
        try finish(existingCount: 0, comment: Data()) { _ in }
    }

    // 旧 CD は一定量ずつ原本から運ぶ。local/central/EOCD の生成は writer と完全に共有する。
    func finish(existingCount: UInt64, comment: Data,
                copyCentral: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        if state == .finished { return }
        try perform {
            let start = position
            try copyCentral(write)
            for entry in entries { try write(entry.central()) }
            try write(ZipRecords.end(count: checkedAdd(existingCount, UInt64(entries.count)),
                                     centralSize: position - start, centralOffset: start, comment: comment))
            try output.truncate(atOffset: position)
            try output.synchronize()
            try output.close()
            state = .finished
        }
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .writing else { throw WriterError.invalidState }
        do {
            if tarWriter != nil || sevenZipWriter != nil || lhaWriter != nil { try Task.checkCancellation() }
            try body()
        } catch {
            state = .failed
            tarWriter?.abort()
            sevenZipWriter?.abort()
            lhaWriter?.abort()
            try? output.close()
            throw error
        }
    }

    private func addDisk(_ url: URL, as path: String, read: (FileHandle, Int) throws -> Data) throws {
        if tarWriter != nil || sevenZipWriter != nil || lhaWriter != nil { try Task.checkCancellation() }
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
                try addDisk(child, as: base + "/" + child.lastPathComponent, read: read)
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
                  opened.st_mode == info.st_mode, opened.st_size == info.st_size, info.st_size >= 0,
                  opened.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  opened.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw WriterError.sourceChanged(url.path)
            }
            let hardLink = try tarWriter?.hardLinkTarget(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                                        signature: Self.linkSignature(info))
            try addEntry(path: path, mode: UInt16(info.st_mode), size: UInt64(info.st_size), date: date, atime: atime,
                         owners: owners, hardLink: hardLink) {
                try read(input, $0)
            }
            var after = stat()
            guard fstat(fd, &after) == 0 else { throw WriterError.io(operation: "fstat after read", code: errno) }
            // Finder tag や LaunchServices の xattr 更新でも変わるため ctime は比較しない。
            guard after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                  after.st_mode == info.st_mode, after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw WriterError.sourceChanged(url.path)
            }
            if info.st_nlink > 1, hardLink == nil, let tarWriter {
                tarWriter.rememberHardLink(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                          signature: Self.linkSignature(info),
                                          path: try Self.normalizedPath(path, directory: false))
            }
        default:
            throw WriterError.unsupportedFileType(url.path)
        }
    }

    // rewriter は展開 stream を同じ serializer に渡す。失敗時の破棄は呼出側が行う。
    func addEntry(
        path: String, mode: UInt16, size: UInt64, date: Date, atime: Date?, owners: (UInt32, UInt32)?,
        hardLink: String? = nil,
        read: (Int) throws -> Data
    ) throws {
        let directory = mode & 0xF000 == 0x4000
        let name = try Self.normalizedPath(path, directory: directory)
        let key = directory ? String(name.dropLast()) : name
        guard names.insert(key).inserted else {
            throw WriterError.duplicatePath(name)
        }
        // file とその子を同居させない。後から親 directory を明示追加することは許す。
        guard directory || !requiredDirectories.contains(key) else { throw WriterError.invalidPath(name) }
        var prefix = ""
        for component in Self.pathComponents(key).dropLast() {
            prefix += prefix.isEmpty ? String(component) : "/" + component
            guard !files.contains(prefix) else { throw WriterError.invalidPath(name) }
            requiredDirectories.insert(prefix)
        }
        if !directory { files.insert(key) }
        if let tarWriter {
            try tarWriter.add(name: name, mode: mode, size: size, date: date, owners: owners, hardLink: hardLink, read: read)
            appendedPaths.append((name, directory))
            return
        }
        if let sevenZipWriter {
            try sevenZipWriter.add(name: name, mode: mode, size: size, date: date, read: read)
            appendedPaths.append((name, directory))
            return
        }
        if let lhaWriter {
            try lhaWriter.add(name: name, mode: mode, size: size, date: date, read: read)
            appendedPaths.append((name, directory))
            return
        }
        let method = compression(name: name, mode: mode, size: size)
        let mtime = try ZipRecords.timestamp(date)
        let accessTime = try ZipRecords.timestamp(atime ?? date)
        let dos = ZipRecords.dosDate(date)
        var entry = ZipRecords.Entry(
            name: Data(name.utf8), method: method, mtime: mtime,
            atime: accessTime, dosTime: dos.time, dosDate: dos.date,
            mode: mode, owners: owners, offset: position, size: size
        )
        let password = mode & 0xF000 == 0x8000 ? options.password : nil
        entry.encryption = password == nil ? nil : options.zipEncryption
        if let password, entry.encryption == .zipCrypto {
            try writeZipCryptoEntry(&entry, name: name, password: password, read: read)
            entries.append(entry)
            appendedPaths.append((name, directory))
            return
        }
        // zlib compressBound の保守的上限。境界付近でも header の領域を後から増やさない。
        var bound = size
        if method == .deflate {
            for extra in [size >> 12, size >> 14, size >> 25, 13] { bound = try checkedAdd(bound, extra) }
        }
        if entry.encryption == .aes256 { bound = try checkedAdd(bound, 28) }
        entry.reservedZIP64 = bound >= ZipRecords.limit
        let header = entry.local()
        try write(header)
        let start = position
        let aes = try password.map { try ZipAESEncryptor(password: $0) }
        if let aes { try write(aes.prefix) }
        entry.crc = try compressEntry(name: name, size: size, method: method, read: read) { chunk in
            try write(aes.map { try $0.encrypt(chunk) } ?? chunk)
        }
        if let aes { try write(aes.finish()) }
        entry.compressedSize = position - start
        let patched = entry.local()
        guard patched.count == header.count else { throw WriterError.sizeOverflow }
        try output.seek(toOffset: entry.offset)
        try output.write(contentsOf: patched)
        try output.seek(toOffset: position)
        entries.append(entry)
        appendedPaths.append((name, directory))
    }

    private func writeZipCryptoEntry(_ entry: inout ZipRecords.Entry, name: String, password: String,
                                     read: (Int) throws -> Data) throws {
        let spool = try ZipCryptoSpool(nextTo: outputURL)
        // spool の deinit は read / 圧縮 / 出力のどの失敗でも一時ファイルを削除する。
        entry.crc = try compressEntry(name: name, size: entry.size, method: entry.method, read: read, emit: spool.write)
        entry.compressedSize = try checkedAdd(spool.size, 12)
        var encryptor = ZipCryptoEncryptor(password: password)
        var header = try EncryptionPrimitives.random(count: 11)
        header.append(UInt8(truncatingIfNeeded: entry.crc >> 24))
        try write(entry.local())
        try write(encryptor.encrypt(header))
        try spool.copy(encryptor: &encryptor, emit: write)
        try spool.remove()
    }

    private func compressEntry(name: String, size: UInt64, method: CompressionMethod,
                               read: (Int) throws -> Data, emit: (Data) throws -> Void) throws -> UInt32 {
        let compressor = method == .deflate ? try DeflateCompressor(level: options.deflateLevel) : nil
        var remaining = size
        var crc: UInt32 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(Self.chunkSize), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            crc = updateCRC(crc, chunk)
            remaining -= UInt64(chunk.count)
            if let compressor { try compressor.write(chunk, emit: emit) } else { try emit(chunk) }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if let compressor { try compressor.write(Data(), finish: true, emit: emit) }
        return crc
    }

    private func write(_ data: Data) throws {
        let next = try checkedAdd(position, UInt64(data.count))
        try output.write(contentsOf: data)
        position = next
    }

    private static func linkSignature(_ info: stat) -> [Int64] {
        // 同じ inode が後から変更されていれば、古い payload への hard link に置き換えない。
        // Finder tag や LaunchServices の xattr 更新でも変わるため ctime は比較しない。
        [info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
         Int64(info.st_mode)]
    }

    private func compression(name: String, mode: UInt16, size: UInt64) -> CompressionMethod {
        guard size > 0, mode & 0xF000 == 0x8000 else { return .stored }
        if options.useCompressionHeuristic {
            let compressed: Set<String> = ["zip", "gz", "bz2", "xz", "7z", "rar", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp3", "mp4", "mov", "pdf"]
            if compressed.contains((name as NSString).pathExtension.lowercased()) { return .stored }
        }
        return options.compressionMethod
    }

    // A combining mark may share a grapheme with /; filesystem separators are bytes.
    static func pathComponents(_ path: String, omittingEmptySubsequences: Bool = true) -> [String] {
        path.utf8.split(separator: 47, omittingEmptySubsequences: omittingEmptySubsequences)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func normalizedPath(_ path: String, directory: Bool) throws -> String {
        var name = path.precomposedStringWithCanonicalMapping
        if directory && !name.hasSuffix("/") { name += "/" }
        let body = directory ? String(name.dropLast()) : name
        let components = pathComponents(body, omittingEmptySubsequences: false)
        guard !body.isEmpty, !body.utf8.contains(0), !body.utf8.contains(92), !body.utf8.contains(58),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.count <= Int(UInt16.max) else { throw WriterError.invalidPath(path) }
        return name
    }
}
