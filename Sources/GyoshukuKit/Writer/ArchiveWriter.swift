import Foundation
private import Darwin

/// ZIP / ZIP64、tar（gzip / bzip2 / XZ 圧縮を含む）、7z、LHA を新規作成する。既存の出力先は上書きしない。
///
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
/// finish() が成功して初めて書庫が完成する。deinit は自動 finish しない。
/// add / finish が失敗した instance は再利用できない（追加を閉じた後の誤った add を除く）。
/// ZIP / 圧縮tar / 7z / LHA の add は出力完了前に戻ることがあり、圧縮失敗は後続の add / finish で通知する。
/// ZIP の部分出力は呼出側で削除する。tar（圧縮tarを含む）/ 7z / LHA は失敗・未完了の破棄時に削除する。
public final class ArchiveWriter {
    public let format: ArchiveFormat
    private let options: WriterOptions
    private let output: FileHandle
    private let outputURL: URL
    private let tarWriter: TarWriter?
    private let sevenZipWriter: SevenZipWriter?
    private let lhaWriter: LHAWriter?
    private var deflateCompressor: DeflateCompressor?
    private struct DeflateTag {
        let entry: ZipRecords.Entry?
        let crc: UInt32?
        var addition: BatchEntry? = nil
    }
    private let deflateBlockSize: Int
    private let zipPipeline: OrderedChunkPipeline<ZipWork, Prefetched, DeflateTag>?
    private let zipSalt: () throws -> Data
    private var emittingEntry: ZipRecords.Entry?
    private var emittingHeaderSize = 0
    private var emittingStart: UInt64 = 0
    private var emittingAES: ZipAESEncryptor?
    private var position: UInt64 = 0
    private var zipOutputBuffer = Data()
    private var zipBufferedAddition: BatchEntry?
    private var appendStart: UInt64 = 0
    private var recordBase: UInt64 = 0
    private var entries: [ZipRecords.Entry] = []
    private(set) var appendedPaths: [(String, Bool)] = []
    private var pendingBatchPaths: [(String, Bool)] = []
    private var names: Set<String> = []
    private var files: Set<String> = []
    private var requiredDirectories: Set<String> = []
    var existingPathCheck: ((String, Bool) throws -> Void)?
    private enum State { case writing, finished, failed }
    private var state = State.writing
    private var additionsClosed = false
    @TaskLocal static var testingAfterPreWalk: (@Sendable () throws -> Void)?
    private static let compressedExtensions: Set<String> = [
        "zip", "gz", "bz2", "xz", "7z", "rar", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp3", "mp4", "mov", "pdf"
    ]

    init(output: FileHandle, url: URL, format: ArchiveFormat, options: WriterOptions,
         tarWriter: TarWriter? = nil, sevenZipWriter: SevenZipWriter? = nil, lhaWriter: LHAWriter? = nil,
         deflateBlockSize: Int = DeflateBlock.size,
         deflateEncoder: @escaping DeflateBlock.Encoder = DeflateBlock.encode,
         zipSalt: @escaping () throws -> Data = { try EncryptionPrimitives.random(count: 16) }) {
        self.output = output
        self.outputURL = url
        self.format = format
        self.options = options
        self.tarWriter = tarWriter
        self.sevenZipWriter = sevenZipWriter
        self.lhaWriter = lhaWriter
        precondition((1...DeflateBlock.size).contains(deflateBlockSize))
        self.deflateBlockSize = deflateBlockSize
        self.zipSalt = zipSalt
        zipPipeline = format == .zip ? OrderedChunkPipeline(threads: options.resolvedCompressionThreads) {
            switch $0 {
            case let .block(block): return Prefetched(data: try deflateEncoder(block, options.deflateLevel), crc: 0)
            case let .file(job): return try job.run { try deflateEncoder($0, options.deflateLevel) }
            }
        } : nil
    }

    deinit {
        zipPipeline?.abandon()
        tarWriter?.abort()
        sevenZipWriter?.abort()
        lhaWriter?.abort()
        try? output.close()
    }

    // writer が閉じた後も rewriter が自分の出力だけを片付けられるよう、descriptor を渡す。
    func duplicateOutput() throws -> FileHandle {
        let fd = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else {
            let code = errno
            ArchiveOwnedFile.remove(url: outputURL, descriptor: output.fileDescriptor)
            throw WriterError.io(operation: "dup writer output", code: code)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// create と同じ新規作成 API。既存書庫を更新する操作ではない。
    /// options を検証してから O_EXCL で出力を新規作成する。
    public static func create(
        url: URL, format: ArchiveFormat = .zip, options: WriterOptions = WriterOptions()
    ) throws -> ArchiveWriter {
        try create(url: url, format: format, options: options,
                   lzmaChunkSize: format == .tarXZ ? ParallelXZCompressor.defaultBlockSize : LZMA2ChunkPipeline<Void>.chunkSize)
    }

    // 小さい入力でも複数 chunk と待機中の失敗を検証できるようにする。
    static func create(
        url: URL, format: ArchiveFormat, options: WriterOptions = WriterOptions(),
        deflateBlockSize: Int = DeflateBlock.size,
        deflateEncoder: @escaping DeflateBlock.Encoder = DeflateBlock.encode,
        bzip2Encoder: @escaping ParallelBzip2Compressor.Encoder = ParallelBzip2Compressor.encode,
        zipSalt: @escaping () throws -> Data = { try EncryptionPrimitives.random(count: 16) },
        lzmaChunkSize: Int,
        xzPackingSize: Int? = nil,
        lzmaEncoder: @escaping LZMA2ChunkPipeline<Void>.Encoder = LZMA2Compressor.encode,
        lh5Encoder: @escaping @Sendable (Data) throws -> Data = LH5Encoder.encode
    ) throws -> ArchiveWriter {
        try FileRead.validateFileURL(url)
        try options.validate(for: format)
        try Task.checkCancellation()
        let compressor: (any TarCompressor)?
        switch format {
        case .tarGzip:
            compressor = try GzipCompressor(level: options.deflateLevel, threads: options.resolvedCompressionThreads,
                                            blockSize: deflateBlockSize, encoder: deflateEncoder)
        case .tarBzip2:
            compressor = try ParallelBzip2Compressor(level: options.bzip2Level, threads: options.resolvedCompressionThreads,
                                                     encoder: bzip2Encoder)
        case .tarXZ:
            compressor = try ParallelXZCompressor(threads: options.resolvedCompressionThreads,
                                                  chunkSize: lzmaChunkSize, packingSize: xzPackingSize, encoder: lzmaEncoder)
        default: compressor = nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666) } ?? -1
        }
        guard fd >= 0 else { throw WriterError.io(operation: "create", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let tar = format.isTar
            ? TarWriter(output: handle, url: url, compressor: compressor) : nil
        let sevenZip = format == .sevenZip
            ? SevenZipWriter(output: handle, url: url, options: options,
                             chunkSize: lzmaChunkSize, encoder: lzmaEncoder) : nil
        let lha = format == .lha ? LHAWriter(output: handle, url: url,
                                            threads: options.resolvedCompressionThreads, encoder: lh5Encoder) : nil
        return ArchiveWriter(output: handle, url: url, format: format, options: options,
                             tarWriter: tar, sevenZipWriter: sevenZip, lhaWriter: lha,
                             deflateBlockSize: deflateBlockSize, deflateEncoder: deflateEncoder, zipSalt: zipSalt)
    }

    /// ディレクトリは名前順で再帰追加する。symlink は辿らず target path を保存する。
    /// LHA は通常ファイルとディレクトリのみ対応し、symlink は拒否する。
    public func add(contentsOf url: URL, as path: String) throws {
        try add(contentsOf: url, as: path) { try FileRead.readChunk($0.fileDescriptor, upTo: $1) }
    }

    /// 通常ファイルの読取 byte を同期通知する。directory は名前順に事前走査して total を固定する。
    /// 圧縮の完了前に (total, total) になることがある。残りは finishAdditions が報告する。
    public func add(contentsOf url: URL, as path: String,
                    progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try add(contentsOf: url, as: path, ownerIDs: nil, progress: progress)
    }

    // 通常の source 読取と stat 検査を共有し、読取中の変更も決定的に検証できる。
    func add(contentsOf url: URL, as path: String, read: (FileHandle, Int) throws -> Data) throws {
        try performAddition { try addDisk(url, as: path, read: read) }
    }

    func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?, expected: DiskSignature? = nil,
             progress: ((ArchiveUpdater.CommitProgress) throws -> Void)? = nil) throws {
        try performAddition {
            try validateOwnerIDs(ownerIDs)
            try addDisk(url, as: path, ownerIDs: ownerIDs, expected: expected, progress: progress) {
                try FileRead.readChunk($0.fileDescriptor, upTo: $1)
            }
        }
    }

    func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?, expected: DiskSignature,
             meter: CommitProgressMeter?) throws {
        try performAddition {
            try validateOwnerIDs(ownerIDs)
            try addDisk(url, as: path, ownerIDs: ownerIDs, expected: expected, meter: meter) {
                try FileRead.readChunk($0.fileDescriptor, upTo: $1)
            }
        }
    }

    private func validateOwnerIDs(_ ids: ArchiveOwnerIDs?) throws {
        if ids != nil, format == .sevenZip || format == .lha { throw WriterError.unsupportedOption("ownerIDs") }
    }

    /// 明示的な空ディレクトリ。mode は 0755、mtime は現在時刻。
    public func addDirectory(_ path: String) throws {
        try addDirectory(path, modificationDate: nil, ownerIDs: nil)
    }

    func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition {
            try validateOwnerIDs(ownerIDs)
            try addEntry(path: path, mode: FileMode.defaultDirectory, size: 0, date: modificationDate ?? Date(), atime: nil,
                         owners: ownerIDs.map { ($0.user, $0.group) }) { _ in Data() }
        }
    }

    /// メモリ上の内容を追加する。mode の既定は 0644。日付は秒単位に切り捨てる。
    /// ZIP は符号付き 32 bit 秒、tar は符号付き 64 bit 秒に収まらない日付を拒否する。
    /// 7z は Windows FILETIME に収まらない日付を拒否する。
    /// LHA は符号なし 32 bit Unix 秒に収まらない日付と CP932 に往復できない名前を拒否する。
    public func add(
        data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil
    ) throws {
        try add(data: data, as: path, modificationDate: modificationDate, permissions: permissions, meter: nil)
    }

    func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?, meter: CommitProgressMeter?) throws {
        try performAddition {
            var offset = 0
            try addEntry(
                path: path, mode: FileMode.regular | ((permissions ?? 0o644) & 0o7777), size: UInt64(data.count),
                date: modificationDate ?? Date(), atime: nil, owners: nil
            ) { requested in
                let count = min(requested, data.count - offset)
                try meter?.advance(UInt64(count))
                defer { offset += count }
                return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
            }
        }
    }

    var pendingInputBytes: UInt64 {
        (zipPipeline?.pendingInputBytes ?? 0) + (tarWriter?.pendingInputBytes ?? 0)
            + (sevenZipWriter?.pendingInputBytes ?? 0) + (lhaWriter?.pendingInputBytes ?? 0)
    }

    /// 受取済みの入力を出力し、追加を閉じる。終端は finish() が書く。
    /// total は呼出し時の待ちの入力 byte で、maximumPendingInputBytes(for:) 以下。
    /// 二度目は (0, 0) を二度通知する。閉じた後の誤った追加で writer は失敗状態にならない。
    public func finishAdditions(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try perform {
            additionsClosed = true
            let meter = progress.map { CommitProgressMeter(total: pendingInputBytes, progress: $0) }
            try meter?.start()
            try finishAdditions(meter: meter)
            try meter?.finish()
        }
    }

    func finishAdditions(meter: CommitProgressMeter?) throws {
        try perform {
            additionsClosed = true
            let advance = meter.map { meter in { (count: UInt64) in try meter.advance(count) } }
            try zipPipeline?.drain(didEmit: advance, emit: emitDeflate)
            try tarWriter?.finishAdditions(didEmit: advance)
            try sevenZipWriter?.finishAdditions(didEmit: advance)
            try lhaWriter?.finishAdditions(didEmit: advance)
        }
    }

    private func performAddition(_ body: () throws -> Void) throws {
        guard !additionsClosed else { throw WriterError.invalidState }
        try perform(body)
    }

    // updater も同じ追加処理を使う。既存名は衝突検査にだけ使い、保存 byte は変更しない。
    func prepareAppend(at offset: UInt64, existingPaths: [(String, Bool)], recordBase: UInt64? = nil) throws {
        try flushZipOutput()
        try output.seek(toOffset: offset)
        position = offset
        appendStart = offset
        self.recordBase = recordBase ?? offset
        replaceExistingPaths(existingPaths)
    }

    // 削除・改名を予約した後の add も、予約済みの名前集合で衝突を検査する。
    func replaceExistingPaths(_ paths: [(String, Bool)]) {
        names.removeAll(keepingCapacity: true)
        files.removeAll(keepingCapacity: true)
        requiredDirectories.removeAll(keepingCapacity: true)
        for (name, directory) in paths + appendedPaths + pendingBatchPaths {
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
    func drainAppendedRecords() throws -> (entries: [ZipRecords.Entry], end: UInt64) {
        try perform { try zipPipeline?.drain(emit: emitDeflate) }
        return (entries, position)
    }

    func endTarMembers() throws -> UInt64 {
        var end: UInt64 = 0
        try perform {
            guard let tarWriter else { throw WriterError.invalidState }
            end = try tarWriter.endMembers()
            state = .finished
        }
        return end
    }

    func endLHAMembers() throws -> UInt64 {
        var end: UInt64 = 0
        try perform {
            guard let lhaWriter else { throw WriterError.invalidState }
            end = try lhaWriter.endMembers()
            state = .finished
        }
        return end
    }

    static func sevenZipAppend(output: FileHandle, url: URL, at offset: UInt64,
                               options: WriterOptions, existingPaths: [(String, Bool)]) throws -> ArchiveWriter {
        let sevenZip = SevenZipWriter(output: output, url: url, options: options, startPosition: offset)
        let writer = ArchiveWriter(output: output, url: url, format: .sevenZip,
                                   options: options, sevenZipWriter: sevenZip)
        try writer.prepareAppend(at: offset, existingPaths: existingPaths)
        return writer
    }

    func endSevenZipEntries() throws -> [SevenZipWriter.AppendedEntry] {
        var records: [SevenZipWriter.AppendedEntry] = []
        try perform {
            guard let sevenZipWriter else { throw WriterError.invalidState }
            records = try sevenZipWriter.endEntries()
            state = .finished
        }
        return records
    }

    func finish(existingCount: UInt64, comment: Data,
                progress: ((UInt64, Int) throws -> Void)? = nil,
                copyCentral: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        if state == .finished { return }
        try perform {
            try zipPipeline?.finish(emit: emitDeflate)
            let start = position
            func emit(_ bytes: Data) throws {
                let offset = position
                try write(bytes)
                if let progress {
                    try flushZipOutput()
                    ZipCopyEngine.writeObserver?(offset, bytes.count)
                    try progress(offset, bytes.count)
                }
            }
            var central = ZipCentralDirectory.CopyValidator(expectedCount: existingCount)
            try copyCentral { bytes in
                try central.consume(bytes)
                try emit(bytes)
            }
            try central.finish()
            for entry in entries {
                try autoreleasepool { try emit(entry.central()) }
            }
            try emit(ZipRecords.end(count: checkedAdd(existingCount, UInt64(entries.count)),
                                     centralSize: position - start, centralOffset: start, comment: comment))
            try flushZipOutput()
            try output.truncate(atOffset: position)
            try output.synchronize()
            try output.close()
            state = .finished
        }
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .writing else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            try autoreleasepool { try body() }
            try flushZipOutput()
        } catch {
            state = .failed
            zipPipeline?.abandon()
            emittingEntry = nil
            emittingAES = nil
            zipOutputBuffer.removeAll()
            zipBufferedAddition = nil
            tarWriter?.abort()
            sevenZipWriter?.abort()
            lhaWriter?.abort()
            try? output.close()
            throw error
        }
    }

    private func addDisk(_ url: URL, as path: String, ownerIDs: ArchiveOwnerIDs? = nil,
                         expected: DiskSignature? = nil,
                         progress: ((ArchiveUpdater.CommitProgress) throws -> Void)? = nil,
                         meter suppliedMeter: CommitProgressMeter? = nil, sourceFailure: ((URL) -> Void)? = nil, read: (FileHandle, Int) throws -> Data) throws {
        do {
            try Task.checkCancellation()
            try FileRead.validateFileURL(url)
            var info = stat()
            let status = url.withUnsafeFileSystemRepresentation { pointer in
                pointer.map { lstat($0, &info) } ?? -1
            }
            guard status == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
            if let expected, !expected.matches(info) { throw WriterError.sourceChanged(url.path) }
            var destination = stat()
            guard fstat(output.fileDescriptor, &destination) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
            let isOutput = ArchiveOwnedFile.hasAssignedInode(destination.st_ino)
                ? info.st_dev == destination.st_dev && info.st_ino == destination.st_ino
                : ArchiveOwnedFile.matches(url: url, descriptor: output.fileDescriptor)
            guard !isOutput else {
                throw WriterError.invalidPath("source contains output archive")
            }
            let session: CommitProgressMeter?
            if let progress {
                let total = try Self.inputByteCount(url, info: info, sourceFailure: sourceFailure)
                session = CommitProgressMeter(total: total, progress: progress)
                try session?.start()
            } else { session = nil }
            let meter = session ?? suppliedMeter
            let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            let atime = Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec))
            let owners = ownerIDs.map { ($0.user, $0.group) } ?? (options.preserveOwnerIDs ? (info.st_uid, info.st_gid) : nil)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try addEntry(path: path, mode: UInt16(info.st_mode), size: 0, date: date, atime: atime, owners: owners) { _ in Data() }
                let base = path.hasSuffix("/") ? String(path.dropLast()) : path
                // 名前は一度だけ取得し、ソート中の Foundation 呼出しを避ける。
                let children = try autoreleasepool {
                    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                        .map { child in autoreleasepool { (url: child, name: child.lastPathComponent) } }
                        .sorted(by: { $0.name < $1.name })
                }
                for child in children {
                    try autoreleasepool {
                        try addDisk(child.url, as: base + "/" + child.name, ownerIDs: ownerIDs, meter: meter, sourceFailure: sourceFailure, read: read)
                    }
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
                try addEntry(path: path, mode: FileMode.defaultSymlink, size: UInt64(count), date: date, atime: atime, owners: owners) { _ in
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
                if let meter {
                    try addEntry(path: path, mode: UInt16(info.st_mode), size: UInt64(info.st_size), date: date, atime: atime,
                                 owners: owners, hardLink: hardLink) {
                        let bytes = try read(input, $0)
                        try meter.advance(UInt64(bytes.count))
                        return bytes
                    }
                } else {
                    try addEntry(path: path, mode: UInt16(info.st_mode), size: UInt64(info.st_size), date: date, atime: atime,
                                 owners: owners, hardLink: hardLink) { try read(input, $0) }
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
                                              path: try Self.normalizedPath(path, directory: false, format: format))
                }
            default:
                throw WriterError.unsupportedFileType(url.path)
            }
            try session?.finish()
        } catch { sourceFailure?(url); throw error }
    }

    // open はせず、追加と同じ名前順で lstat する。symlink の target は数えない。
    static func inputByteCount(_ url: URL) throws -> UInt64 {
        var info = stat()
        try FileRead.validateFileURL(url)
        guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
        return try inputByteCount(url, info: info)
    }

    private static func inputByteCount(_ url: URL, info: stat, sourceFailure: ((URL) -> Void)? = nil) throws -> UInt64 {
        func walk(_ url: URL, info: stat) throws -> UInt64 {
            do {
                try Task.checkCancellation()
                if info.st_mode & S_IFMT == S_IFREG { return UInt64(max(0, info.st_size)) }
                guard info.st_mode & S_IFMT == S_IFDIR else { return 0 }
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .map { (url: $0, name: $0.lastPathComponent) }.sorted { $0.name < $1.name }
                var total: UInt64 = 0
                for child in children {
                    try autoreleasepool {
                        var childInfo = stat()
                        guard lstat(child.url.path, &childInfo) == 0 else {
                            let code = errno
                            sourceFailure?(child.url)
                            throw WriterError.io(operation: "lstat", code: code)
                        }
                        total = try checkedAdd(total, walk(child.url, info: childInfo))
                    }
                }
                return total
            } catch { sourceFailure?(url); throw error }
        }
        let total = try walk(url, info: info)
        if info.st_mode & S_IFMT == S_IFDIR { try testingAfterPreWalk?() }
        return total
    }

    func reserveEntryName(_ path: String, directory: Bool) throws -> String {
        let name = try Self.normalizedPath(path, directory: directory, format: format)
        let key = directory ? String(name.dropLast()) : name
        try existingPathCheck?(name, directory)
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
        return name
    }

    // rewriter は展開 stream を同じ serializer に渡す。失敗時の破棄は呼出側が行う。
    func addEntry(
        path: String, mode: UInt16, size: UInt64, date: Date, atime: Date?, owners: (UInt32, UInt32)?,
        hardLink: String? = nil,
        read: (Int) throws -> Data
    ) throws {
        guard state == .writing, !additionsClosed else { throw WriterError.invalidState }
        let directory = mode.isDirectoryMode
        let name = try reserveEntryName(path, directory: directory)
        try addReservedEntry(name: name, mode: mode, size: size, date: date, atime: atime,
                             owners: owners, hardLink: hardLink, read: read)
    }

    private func addReservedEntry(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?,
                                  owners: (UInt32, UInt32)?, hardLink: String?, read: (Int) throws -> Data) throws {
        let directory = mode.isDirectoryMode
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
        try Task.checkCancellation()
        let method = compression(name: name, mode: mode, size: size)
        if method == .stored || (options.password != nil && options.zipEncryption == .zipCrypto) {
            try zipPipeline?.drain(emit: emitDeflate)
        }
        var entry = try makeZipEntry(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners, method: method)
        let password = mode.isRegularFileMode ? options.password : nil
        if let password, entry.encryption == .zipCrypto {
            try writeZipCryptoEntry(&entry, name: name, password: password, read: read)
            entries.append(entry)
            appendedPaths.append((name, directory))
            return
        }
        var bound = method == .deflate ? try DeflateBlock.bound(size: size, blockSize: deflateBlockSize) : size
        if entry.encryption == .aes256 { bound = try checkedAdd(bound, 28) }
        entry.reservedZIP64 = bound >= ZipRecords.limit
        if method == .deflate {
            try submitDeflate(entry, name: name, read: read)
            appendedPaths.append((name, directory))
            return
        }
        let header = entry.local()
        try write(header)
        let start = position
        let aes = try password.map { try ZipAESEncryptor(password: $0, salt: zipSalt()) }
        if let aes { try write(aes.prefix) }
        entry.crc = try compressEntry(name: name, size: size, method: method, read: read) { chunk in
            try write(aes.map { try $0.encrypt(chunk) } ?? chunk)
        }
        if let aes { try write(aes.finish()) }
        entry.compressedSize = position - start
        let patched = entry.local()
        guard patched.count == header.count else { throw WriterError.sizeOverflow }
        try flushZipOutput()
        try output.seek(toOffset: checkedAdd(appendStart, entry.offset - recordBase))
        try output.write(contentsOf: patched)
        try output.seek(toOffset: position)
        entries.append(entry)
        appendedPaths.append((name, directory))
    }

    private func submitDeflate(_ entry: ZipRecords.Entry, name: String, read: (Int) throws -> Data) throws {
        let pipeline = zipPipeline!
        var remaining = entry.size
        var first = true
        var crc: UInt32 = 0
        var dictionary = Data()
        while remaining > 0 {
            try pipeline.waitForCapacity(emit: emitDeflate)
            let count = Int(min(remaining, UInt64(deflateBlockSize)))
            var input = Data()
            input.reserveCapacity(count)
            while input.count < count {
                try Task.checkCancellation()
                let requested = min(IOChunk.size, count - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                input.append(chunk)
                crc = updateCRC(crc, chunk)
            }
            remaining -= UInt64(count)
            if remaining == 0, try !read(1).isEmpty { throw WriterError.sourceChanged(name) }
            let block = DeflateBlock(input: input, dictionary: dictionary, final: remaining == 0)
            dictionary = remaining == 0 ? Data() : DeflateBlock.dictionary(from: input)
            try pipeline.submit(.block(block), tag: DeflateTag(entry: first ? entry : nil, crc: remaining == 0 ? crc : nil),
                                weight: UInt64(input.count), emit: emitDeflate)
            first = false
        }
    }

    private func emitDeflate(_ tag: DeflateTag, _ result: Prefetched?) throws {
        try Task.checkCancellation()
        if let entry = tag.entry, let crc = tag.crc {
            try emitCompleteZip(entry, data: result!.data, crc: crc)
            return
        }
        if var entry = tag.entry {
            entry.offset = try checkedAdd(recordBase, position - appendStart)
            emittingEntry = entry
            let header = entry.local()
            emittingHeaderSize = header.count
            try write(header)
            emittingStart = position
            emittingAES = try options.password.map { try ZipAESEncryptor(password: $0, salt: zipSalt()) }
            if let emittingAES { try write(emittingAES.prefix) }
        }
        let compressed = result!.data
        for offset in stride(from: compressed.startIndex, to: compressed.endIndex, by: IOChunk.size) {
            let chunk = compressed[offset..<min(offset + IOChunk.size, compressed.endIndex)]
            try write(emittingAES.map { try $0.encrypt(chunk) } ?? chunk)
        }
        if let crc = tag.crc {
            if let emittingAES { try write(emittingAES.finish()) }
            var entry = emittingEntry!
            entry.crc = crc
            entry.compressedSize = position - emittingStart
            let patched = entry.local()
            guard patched.count == emittingHeaderSize else { throw WriterError.sizeOverflow }
            try flushZipOutput()
            try output.seek(toOffset: checkedAdd(appendStart, entry.offset - recordBase))
            try output.write(contentsOf: patched)
            try output.seek(toOffset: position)
            entries.append(entry)
            emittingEntry = nil
            emittingAES = nil
        }
    }

    private func makeZipEntry(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?,
                              owners: (UInt32, UInt32)?, method: CompressionMethod) throws -> ZipRecords.Entry {
        let dos = ZipRecords.dosDate(date)
        var entry = ZipRecords.Entry(name: Data(name.utf8), method: method,
            mtime: try ZipRecords.timestamp(date), atime: try ZipRecords.timestamp(atime ?? date),
            dosTime: dos.time, dosDate: dos.date, mode: mode, owners: owners,
            offset: try checkedAdd(recordBase, position - appendStart), size: size)
        entry.encryption = mode.isRegularFileMode && options.password != nil ? options.zipEncryption : nil
        return entry
    }

    // 完成済みの単一 block は、既存と同じ header/data を一度の write で出力する。
    private func emitCompleteZip(_ source: ZipRecords.Entry, data: Data, crc: UInt32, addition: BatchEntry? = nil) throws {
        var entry = source
        entry.offset = try checkedAdd(recordBase, position - appendStart)
        entry.crc = crc
        var payload = data
        if entry.encryption == .aes256 {
            let aes = try ZipAESEncryptor(password: options.password!, salt: zipSalt())
            payload = aes.prefix
            payload.append(try aes.encrypt(data))
            payload.append(try aes.finish())
        }
        entry.compressedSize = UInt64(payload.count)
        var record = entry.local()
        record.append(payload)
        try write(record, addition: addition)
        entries.append(entry)
    }

    private func writeZipCryptoEntry(_ entry: inout ZipRecords.Entry, name: String, password: String,
                                     read: (Int) throws -> Data) throws {
        let spool = try ZipCryptoSpool(nextTo: outputURL)
        // spool は作成直後に unlink 済み。どの失敗でも deinit で descriptor を閉じる。
        entry.crc = try compressEntry(name: name, size: entry.size, method: entry.method, read: read, emit: spool.write)
        entry.compressedSize = try checkedAdd(spool.size, 12)
        var encryptor = ZipCryptoEncryptor(password: password)
        var header = try ArchiveUpdater.testingRandomBytes?(11) ?? EncryptionPrimitives.random(count: 11)
        header.append(UInt8(truncatingIfNeeded: entry.crc >> 24))
        try write(entry.local())
        try write(encryptor.encrypt(header))
        try spool.copy(encryptor: &encryptor, emit: write)
        try spool.close()
    }

    private func compressEntry(name: String, size: UInt64, method: CompressionMethod,
                               read: (Int) throws -> Data, emit: (Data) throws -> Void) throws -> UInt32 {
        let compressor: DeflateCompressor?
        if method == .deflate {
            if let deflateCompressor {
                try deflateCompressor.reset()
            } else {
                deflateCompressor = try DeflateCompressor(level: options.deflateLevel)
            }
            compressor = deflateCompressor
        } else {
            compressor = nil
        }
        var remaining = size
        var crc: UInt32 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(IOChunk.size), remaining))
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
        try write(data, addition: nil)
    }

    private func write(_ data: Data, addition: BatchEntry?) throws {
        try Task.checkCancellation()
        let next = try checkedAdd(position, UInt64(data.count))
        if data.count >= IOChunk.size {
            try flushZipOutput()
            try output.write(contentsOf: data)
        } else {
            if zipOutputBuffer.count + data.count > IOChunk.size { try flushZipOutput() }
            if zipOutputBuffer.isEmpty { zipBufferedAddition = addition }
            zipOutputBuffer.append(data)
        }
        position = next
    }

    // position は論理 offset。seek、外部への引渡し、公開操作の完了前には実際に書き出す。
    private func flushZipOutput() throws {
        guard !zipOutputBuffer.isEmpty else { return }
        try Task.checkCancellation()
        do { try output.write(contentsOf: zipOutputBuffer) }
        catch {
            // 一括 write の失敗は、まだ書き終えていない最初の項目へ帰属させる。
            if let entry = zipBufferedAddition { throw additionFailure(error, index: entry.index, addition: entry.addition) }
            throw error
        }
        zipOutputBuffer.removeAll(keepingCapacity: true)
        zipBufferedAddition = nil
    }

    private static func linkSignature(_ info: stat) -> [Int64] {
        // 同じ inode が後から変更されていれば、古い payload への hard link に置き換えない。
        // Finder tag や LaunchServices の xattr 更新でも変わるため ctime は比較しない。
        [info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
         Int64(info.st_mode)]
    }

    private func compression(name: String, mode: UInt16, size: UInt64) -> CompressionMethod {
        guard size > 0, mode.isRegularFileMode else { return .stored }
        if options.useCompressionHeuristic {
            if Self.compressedExtensions.contains((name as NSString).pathExtension.lowercased()) { return .stored }
        }
        return options.compressionMethod
    }

    // A combining mark may share a grapheme with /; filesystem separators are bytes.
    static func pathComponents(_ path: String, omittingEmptySubsequences: Bool = true) -> [String] {
        path.utf8.split(separator: 47, omittingEmptySubsequences: omittingEmptySubsequences)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func normalizedPath(_ path: String, directory: Bool, format: ArchiveFormat) throws -> String {
        var name = path.precomposedStringWithCanonicalMapping
        if directory && !name.hasSuffix("/") { name += "/" }
        let body = directory ? String(name.dropLast()) : name
        let components = pathComponents(body, omittingEmptySubsequences: false)
        // tar は名前中の \ と : を許す。ZIP / 7z / LHA は Windows 向けの制約を保つ。
        guard !body.isEmpty, !body.utf8.contains(0),
              format.isTar || (!body.utf8.contains(92) && !body.utf8.contains(58)),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.count <= Int(UInt16.max) else { throw WriterError.invalidPath(path) }
        return name
    }
}

// 全ての名前の予約と出力は呼出側。worker は検証済みの内容だけを返す。
extension ArchiveWriter {
    private struct BatchEntry {
        let index: Int
        let addition: ArchiveAddition
        let name: String
        let mode: UInt16
        let size: UInt64
        let date: Date
        let atime: Date?
        let owners: (UInt32, UInt32)?
        let hardLink: String?
        let inline: Data
        let zip: ZipRecords.Entry?
        var inputBytes: UInt64 { mode.isRegularFileMode ? size : 0 }
    }

    /// 項目別 API と同じ byte を出力する、有界の並列先読み。
    /// ownerIDs と directory の日時を指定できる公開の入口。
    /// 名前の予約は open より前。失敗は最小の index に帰属し、events の throw と取消しは包まない。
    /// events は呼出しの thread で同期通知し、保持しない。
    /// 空配列は状態や取消しにかかわらず何もせず、events を通知せず、待ち入力も出力しない。
    /// finishAdditions / finish の動作と出力 byte は呼ばなかった場合と同じ。
    public func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        try add(additions, expected: nil, meter: nil, events: events)
    }

    func add(_ additions: [ArchiveAddition], expected: [DiskSignature?]?, meter: CommitProgressMeter?,
             events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        guard !additions.isEmpty else { return }
        guard !additionsClosed else { throw WriterError.invalidState }
        precondition(expected == nil || expected!.count == additions.count)
        let limiter = SourcePrefetchLimiter(threads: options.resolvedCompressionThreads)
        let prefetch = format == .zip || format == .sevenZip ? nil : OrderedChunkPipeline<FileJob, Prefetched, BatchEntry>(
            threads: options.resolvedCompressionThreads) { try $0.run { _ in throw WriterError.invalidState } }
        func receive(_ entry: BatchEntry, _ result: Prefetched?) throws {
            do {
                try Task.checkCancellation()
                try additionEvent(.progress(index: entry.index, .init(completedBytes: 0, totalBytes: entry.inputBytes)), events)
                guard state == .writing, !additionsClosed else { throw WriterError.invalidState }
                let data = result?.data ?? entry.inline
                if let zip = entry.zip {
                    try emitCompleteZip(zip, data: data, crc: result?.crc ?? updateCRC(0, data), addition: entry)
                    appendedPaths.append((entry.name, entry.mode.isDirectoryMode))
                } else if let sevenZipWriter {
                    try sevenZipWriter.add(name: entry.name, mode: entry.mode, date: entry.date,
                                           prefetched: result ?? Prefetched(data: data, crc: updateCRC(0, data)))
                    appendedPaths.append((entry.name, entry.mode.isDirectoryMode))
                } else {
                    var offset = 0
                    try addReservedEntry(name: entry.name, mode: entry.mode, size: entry.size, date: entry.date,
                                         atime: entry.atime, owners: entry.owners, hardLink: entry.hardLink) { requested in
                        let count = min(requested, data.count - offset)
                        defer { offset += count }
                        if offset == 0, count == data.count { return data }
                        return data.subdata(in: offset..<(offset + count))
                    }
                }
                // 通知の時点と add の戻りでは実際の出力が揃っている。
                if events != nil || entry.index == additions.count - 1 {
                    try flushZipOutput()
                }
                pendingBatchPaths.removeFirst()
                do { try meter?.advance(entry.hardLink == nil ? entry.inputBytes : 0) }
                catch { throw AdditionEventFailure(underlying: error) }
                try additionEvent(.progress(index: entry.index, .init(completedBytes: entry.inputBytes, totalBytes: entry.inputBytes)), events)
                try additionEvent(.didFinish(index: entry.index), events)
            } catch { throw additionFailure(error, index: entry.index, addition: entry.addition) }
        }
        func emit(_ tag: DeflateTag, _ result: Prefetched?) throws {
            if let entry = tag.addition { try receive(entry, result) }
            else { try emitDeflate(tag, result) }
        }
        func drain() throws {
            try zipPipeline?.drain(emit: emit)
            try prefetch?.drain(emit: receive)
        }
        do {
            try performAddition {
                do {
                    for (index, addition) in additions.enumerated() {
                        try autoreleasepool {
                            // 後続の willStart を通知する前に窓の空きを作る。
                            try zipPipeline?.waitForCapacity(emit: emit)
                            try prefetch?.waitForCapacity(emit: receive)
                            do {
                                try additionEvent(.willStart(index: index), events)
                                try Task.checkCancellation()
                                guard state == .writing, !additionsClosed else { throw WriterError.invalidState }
                                try validateOwnerIDs(addition.ownerIDs)
                                var info = stat()
                                var cPath: [CChar] = []
                                var inline = Data()
                                let date: Date
                                let atime: Date?
                                let mode: UInt16
                                let size: UInt64
                                let owners: (UInt32, UInt32)?
                                switch addition.source {
                                case let .directory(explicitDate):
                                    date = explicitDate ?? Date(); atime = nil; mode = FileMode.defaultDirectory; size = 0
                                    owners = addition.ownerIDs.map { ($0.user, $0.group) }
                                case let .contents(url):
                                    try FileRead.validateFileURL(url)
                                    cPath = url.withUnsafeFileSystemRepresentation { pointer in
                                        pointer.map { Array(UnsafeBufferPointer(start: $0, count: strlen($0) + 1)) } ?? []
                                    }
                                    try FileJob.testingBeforeLstat?(index, url)
                                    guard !cPath.isEmpty, cPath.withUnsafeBufferPointer({ lstat($0.baseAddress!, &info) }) == 0 else {
                                        throw WriterError.io(operation: "lstat", code: errno)
                                    }
                                    if let signature = expected?[index], !signature.matches(info) { throw WriterError.sourceChanged(url.path) }
                                    var destination = stat()
                                    guard fstat(output.fileDescriptor, &destination) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
                                    let isOutput = ArchiveOwnedFile.hasAssignedInode(destination.st_ino)
                                        ? info.st_dev == destination.st_dev && info.st_ino == destination.st_ino
                                        : ArchiveOwnedFile.matches(url: url, descriptor: output.fileDescriptor)
                                    guard !isOutput else { throw WriterError.invalidPath("source contains output archive") }
                                    mode = info.st_mode & S_IFMT == S_IFLNK ? FileMode.defaultSymlink : UInt16(info.st_mode)
                                    date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                                    atime = Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec))
                                    owners = addition.ownerIDs.map { ($0.user, $0.group) }
                                        ?? (options.preserveOwnerIDs ? (info.st_uid, info.st_gid) : nil)
                                    let kind = info.st_mode & S_IFMT
                                    let threshold = format == .zip &&
                                        compression(name: addition.path, mode: mode, size: UInt64(max(0, info.st_size))) == .deflate
                                        ? deflateBlockSize : DeflateBlock.size
                                    if kind == S_IFDIR || (kind == S_IFREG && (info.st_size > threshold ||
                                        (format == .zip && options.password != nil && options.zipEncryption == .zipCrypto))) {
                                        try drain()
                                        var failedSource: URL?
                                        do {
                                            try addDisk(url, as: addition.path, ownerIDs: addition.ownerIDs,
                                                        expected: expected?[index] ?? DiskSignature(info),
                                                        progress: events.map { events in { try additionEvent(.progress(index: index, $0), events) } },
                                                        meter: meter, sourceFailure: { if failedSource == nil { failedSource = $0 } }) {
                                                try FileRead.readChunk($0.fileDescriptor, upTo: $1)
                                            }
                                            // ZIP の遅延 block の失敗も、この fallback 項目へ帰属させる。
                                            try zipPipeline?.drain(emit: emit)
                                            try flushZipOutput()
                                        } catch { throw additionFailure(error, index: index, addition: addition, sourceURL: failedSource) }
                                        try additionEvent(.didFinish(index: index), events)
                                        return
                                    }
                                    if kind == S_IFLNK {
                                        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
                                        let count = cPath.withUnsafeBufferPointer { readlink($0.baseAddress!, &buffer, buffer.count) }
                                        guard count >= 0 else { throw WriterError.io(operation: "readlink", code: errno) }
                                        guard count < buffer.count else { throw WriterError.sourceChanged(url.path) }
                                        inline = Data(buffer.prefix(count)); size = UInt64(count)
                                    } else if kind == S_IFREG, info.st_size >= 0 {
                                        size = UInt64(info.st_size)
                                    } else { throw WriterError.unsupportedFileType(url.path) }
                                }
                                let name = try reserveEntryName(addition.path, directory: mode.isDirectoryMode)
                                var hardLink: String?
                                if mode.isRegularFileMode, let tarWriter {
                                    hardLink = try tarWriter.hardLinkTarget(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                                                         signature: Self.linkSignature(info))
                                    if info.st_nlink > 1, hardLink == nil {
                                        tarWriter.rememberHardLink(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                                                  signature: Self.linkSignature(info), path: name)
                                    }
                                }
                                var zip = format == .zip ? try makeZipEntry(name: name, mode: mode, size: size, date: date, atime: atime,
                                    owners: owners, method: compression(name: name, mode: mode, size: size)) : nil
                                if var entry = zip {
                                    var bound = entry.method == .deflate ? try DeflateBlock.bound(size: size, blockSize: deflateBlockSize) : size
                                    if entry.encryption == .aes256 { bound = try checkedAdd(bound, 28) }
                                    entry.reservedZIP64 = bound >= ZipRecords.limit
                                    zip = entry
                                }
                                let entry = BatchEntry(index: index, addition: addition, name: name, mode: mode, size: size,
                                                       date: date, atime: atime, owners: owners, hardLink: hardLink, inline: inline, zip: zip)
                                pendingBatchPaths.append((name, mode.isDirectoryMode))
                                let job = mode.isRegularFileMode ? FileJob(index: index, addition: addition, path: cPath,
                                    expected: DiskSignature(info), size: Int(size), deflate: zip?.method == .deflate, limiter: limiter) : nil
                                if let zipPipeline {
                                    try zipPipeline.submit(job.map { .file($0) }, tag: .init(entry: nil, crc: nil, addition: entry),
                                                           weight: entry.inputBytes, emit: emit)
                                } else if sevenZipWriter != nil {
                                    // LZMA2 の窓と I/O は重なる。追加の reader queue は小ファイルで encoder と競合する。
                                    try receive(entry, job.map { try $0.run { _ in throw WriterError.invalidState } })
                                } else {
                                    try prefetch!.submit(job, tag: entry, weight: entry.inputBytes, emit: receive)
                                }
                            } catch {
                                if !(error is CancellationError || error is AdditionEventFailure || error is ArchiveAdditionError) {
                                    // 準備の失敗より前の worker の失敗を優先する。
                                    try drain()
                                }
                                throw additionFailure(error, index: index, addition: addition)
                            }
                        }
                    }
                    try drain()
                    try Task.checkCancellation()
                } catch {
                    limiter.cancel()
                    zipPipeline?.abandonAndWait()
                    prefetch?.abandonAndWait()
                    pendingBatchPaths.removeAll()
                    // 検証済みの前方の項目の write 失敗も、後方の source 失敗より優先する。
                    if let failed = error as? ArchiveAdditionError,
                       let buffered = zipBufferedAddition, buffered.index < failed.index {
                        try flushZipOutput()
                    }
                    throw error
                }
            }
        } catch let error as AdditionEventFailure { throw error.underlying }
    }
}
