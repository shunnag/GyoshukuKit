import Foundation
private import Darwin

/// ZIP / ZIP64、tar（9種の stream 圧縮を含む）、7z、LHA を新規作成する。既存の出力先は上書きしない。
///
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
/// finish() が成功して初めて書庫が完成する。deinit は自動 finish しない。
/// add / finish が失敗した instance は再利用できない（追加を閉じた後の誤った add を除く）。
/// ZIP / 圧縮tar / 7z / LHA の add は出力完了前に戻ることがあり、圧縮失敗は後続の add / finish で通知する。
/// ZIP の部分出力は呼出側で削除する。tar（圧縮tarを含む）/ 7z / LHA は失敗・未完了の破棄時に削除する。
///
/// 名前の検証・衝突検査・ディスク探索・一括追加の先読みをここで行い、record の直列化は形式ごとの
/// writer（ZipWriter / TarWriter / SevenZipWriter / LHAWriter）のうち format に対応する一つに渡す。
public final class ArchiveWriter {
    public let format: ArchiveFormat
    private let options: WriterOptions
    private let output: FileHandle
    private let outputURL: URL
    private let zipWriter: ZipWriter?
    private let tarWriter: TarWriter?
    private let sevenZipWriter: SevenZipWriter?
    private let lhaWriter: LHAWriter?
    private(set) var appendedPaths: [(String, Bool)] = []
    private var pendingBatch: [BatchEntry] = []
    private var names: Set<String> = []
    private var files: Set<String> = []
    private var requiredDirectories: Set<String> = []
    var existingPathCheck: ((String, Bool) throws -> Void)?
    private enum State { case writing, finished, failed }
    private var state = State.writing
    private var additionsClosed = false
    @TaskLocal static var testingAfterPreWalk: (@Sendable () throws -> Void)?
    // 一括追加が項目の lstat を呼ぶ直前。呼出しの thread で同期的に呼ぶ。
    @TaskLocal static var testingBeforeLstat: (@Sendable (Int, URL) throws -> Void)?

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
        zipWriter = format == .zip
            ? ZipWriter(output: output, url: url, options: options, deflateBlockSize: deflateBlockSize,
                        deflateEncoder: deflateEncoder, salt: zipSalt) : nil
    }

    deinit {
        zipWriter?.abort()
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
        let piece = format == .tarXZ || (format == .sevenZip && options.sevenZipMethod == .lzma2)
            ? try LZMAWriterConfiguration(options: options).pieceSize : LZMA2ChunkPipeline<Void>.chunkSize
        return try create(url: url, format: format, options: options, lzmaChunkSize: piece)
    }

    // 小さい入力でも複数 chunk と待機中の失敗を検証できるようにする。
    static func create(
        url: URL, format: ArchiveFormat, options: WriterOptions = WriterOptions(),
        deflateBlockSize: Int = DeflateBlock.size,
        deflateEncoder: @escaping DeflateBlock.Encoder = DeflateBlock.encode,
        bzip2Encoder: @escaping ParallelBzip2Compressor.Encoder = Bzip2StreamEncoder.encode,
        zipSalt: @escaping () throws -> Data = { try EncryptionPrimitives.random(count: 16) },
        lzmaChunkSize: Int,
        xzPackingSize: Int? = nil,
        lzmaEncoder: LZMA2ChunkPipeline<Void>.Encoder? = nil,
        lh5Encoder: (@Sendable (Data) throws -> Data)? = nil
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
            let configuration = try LZMAWriterConfiguration(options: options)
            compressor = try ParallelXZCompressor(threads: configuration.threads,
                chunkSize: lzmaChunkSize, packingSize: xzPackingSize, allowsLightChunks: configuration.properties == nil,
                encoder: lzmaEncoder ?? configuration.encoder)
        case .tarZstd, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress:
            compressor = try StreamCompressor.make(format: format, options: options)
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
            ? try SevenZipWriter(output: handle, url: url, options: options,
                             chunkSize: lzmaChunkSize, encoder: lzmaEncoder) : nil
        let lha = format == .lha ? LHAWriter(output: handle, url: url,
                                            threads: options.resolvedCompressionThreads,
                                            method: options.lhaMethod, level: options.lhaLevel, encoder: lh5Encoder) : nil
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
        (zipWriter?.pendingInputBytes ?? 0) + (tarWriter?.pendingInputBytes ?? 0)
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
            try zipWriter?.finishAdditions(didEmit: advance)
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
        try zipWriter?.flushOutput()
        try output.seek(toOffset: offset)
        zipWriter?.prepareAppend(at: offset, recordBase: recordBase)
        replaceExistingPaths(existingPaths)
    }

    // 削除・改名を予約した後の add も、予約済みの名前集合で衝突を検査する。
    func replaceExistingPaths(_ paths: [(String, Bool)]) {
        names.removeAll(keepingCapacity: true)
        files.removeAll(keepingCapacity: true)
        requiredDirectories.removeAll(keepingCapacity: true)
        for (name, directory) in paths + appendedPaths + pendingBatch.map({ ($0.name, $0.mode.isDirectoryMode) }) {
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
        if let lhaWriter { return try finishSubWriter { try lhaWriter.finish() } }
        if let sevenZipWriter { return try finishSubWriter { try sevenZipWriter.finish() } }
        if let tarWriter { return try finishSubWriter { try tarWriter.finish() } }
        try finish(existingCount: 0, comment: Data()) { _ in }
    }

    // tar / 7z / LHA の終端は各 writer が書く。成功後の再呼出しは何もしない。
    private func finishSubWriter(_ finish: () throws -> Void) throws {
        if state == .finished { return }
        try perform {
            try finish()
            state = .finished
        }
    }

    // 旧 CD は一定量ずつ原本から運ぶ。local/central/EOCD の生成は writer と完全に共有する。
    func drainAppendedRecords() throws -> ZipWriter.AppendedRecords {
        var appended: ZipWriter.AppendedRecords = ([], 0)
        try perform { appended = try requireZipWriter().drainAppendedRecords() }
        return appended
    }

    // updater の末尾追加の入口。形式の writer に offset から書かせ、既存名は衝突検査にだけ使う。
    // 追加を閉じるのは endAppendedMembers（tar / LHA）と endSevenZipEntries（7z）。終端は updater が書く。
    static func tarAppend(output: FileHandle, url: URL, at offset: UInt64, options: WriterOptions,
                          existingPaths: [(String, Bool)], recordsMemberLayout: Bool = false,
                          willWrite: ((Int) throws -> Void)? = nil) throws -> ArchiveWriter {
        let tar = TarWriter(output: output, url: url, compressor: nil, startPosition: offset,
                            recordsMemberLayout: recordsMemberLayout, observesWrites: true, willWrite: willWrite)
        let writer = ArchiveWriter(output: output, url: url, format: .tar, options: options, tarWriter: tar)
        try writer.prepareAppend(at: offset, existingPaths: existingPaths)
        return writer
    }

    static func lhaAppend(output: FileHandle, url: URL, at offset: UInt64, options: WriterOptions,
                          existingPaths: [(String, Bool)],
                          encoder: (@Sendable (Data) throws -> Data)?) throws -> ArchiveWriter {
        let lha = LHAWriter(output: output, url: url, threads: options.resolvedCompressionThreads,
                            method: options.lhaMethod, level: options.lhaLevel,
                            recordsMembers: true, encoder: encoder)
        let writer = ArchiveWriter(output: output, url: url, format: .lha, options: options, lhaWriter: lha)
        try writer.prepareAppend(at: offset, existingPaths: existingPaths)
        return writer
    }

    static func sevenZipAppend(output: FileHandle, url: URL, at offset: UInt64,
                               options: WriterOptions, existingPaths: [(String, Bool)]) throws -> ArchiveWriter {
        let sevenZip = try SevenZipWriter(output: output, url: url, options: options, startPosition: offset)
        let writer = ArchiveWriter(output: output, url: url, format: .sevenZip,
                                   options: options, sevenZipWriter: sevenZip)
        try writer.prepareAppend(at: offset, existingPaths: existingPaths)
        return writer
    }

    /// tar / LHA の末尾追加を閉じ、最後の member の直後の位置を返す。終端は書かない。
    func endAppendedMembers() throws -> UInt64 {
        var end: UInt64 = 0
        try perform {
            if let tarWriter { end = try tarWriter.endMembers() }
            else if let lhaWriter { end = try lhaWriter.endMembers() }
            else { throw WriterError.invalidState }
            state = .finished
        }
        return end
    }

    // tarAppend(recordsMemberLayout: true) と lhaAppend が記録した追加 member。endAppendedMembers の後に読む。
    var appendedTarMemberLayouts: [(groupStart: UInt64, dataStart: UInt64, end: UInt64)] { tarWriter?.memberLayouts ?? [] }
    var appendedLHAMemberRecords: [LHAWriter.MemberRecord] { lhaWriter?.memberRecords ?? [] }

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
            try requireZipWriter().finish(existingCount: existingCount, comment: comment, progress: progress, copyCentral: copyCentral)
            state = .finished
        }
    }

    private func requireZipWriter() throws -> ZipWriter {
        guard let zipWriter else { throw WriterError.invalidState }
        return zipWriter
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .writing else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            try autoreleasepool { try body() }
            try zipWriter?.flushOutput()
        } catch {
            state = .failed
            zipWriter?.abort()
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
            guard try !isOutputFile(info, url: url) else {
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
                try addDirectoryChildren(url, as: path, ownerIDs: ownerIDs, meter: meter, sourceFailure: sourceFailure, read: read)
            case S_IFLNK:
                var payload = try url.withUnsafeFileSystemRepresentation { pointer in
                    guard let pointer else { throw WriterError.io(operation: "readlink", code: errno) }
                    return try Self.symlinkTarget(at: pointer, url: url)
                }
                try addEntry(path: path, mode: FileMode.defaultSymlink, size: UInt64(payload.count), date: date, atime: atime,
                             owners: owners) { _ in
                    defer { payload = Data() }
                    return payload
                }
            case S_IFREG:
                try addRegularFile(url, as: path, info: info, date: date, atime: atime, owners: owners, meter: meter, read: read)
            default:
                throw WriterError.unsupportedFileType(url.path)
            }
            try session?.finish()
        } catch { sourceFailure?(url); throw error }
    }

    // 子を名前順に addDisk へ渡す。
    private func addDirectoryChildren(_ url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?, meter: CommitProgressMeter?,
                                      sourceFailure: ((URL) -> Void)?, read: (FileHandle, Int) throws -> Data) throws {
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
    }

    // lstat 済みの通常ファイルを開いて追加する。open 後と読取後の fstat が lstat の結果と違えば sourceChanged。
    private func addRegularFile(_ url: URL, as path: String, info: stat, date: Date, atime: Date, owners: (UInt32, UInt32)?,
                                meter: CommitProgressMeter?, read: (FileHandle, Int) throws -> Data) throws {
        // lstat と open の間に symlink へ置換されても辿らない。
        let fd = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw WriterError.io(operation: "open source", code: errno) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        let signature = DiskSignature(info)
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw WriterError.io(operation: "fstat source", code: errno) }
        guard signature.matches(opened), info.st_size >= 0 else { throw WriterError.sourceChanged(url.path) }
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
        guard signature.matches(after) else { throw WriterError.sourceChanged(url.path) }
        if info.st_nlink > 1, hardLink == nil, let tarWriter {
            tarWriter.rememberHardLink(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                      signature: Self.linkSignature(info),
                                      path: try Self.normalizedPath(path, directory: false, format: format))
        }
    }

    // source が書込み中の出力そのものか。仮 inode の FAT / exFAT では path と descriptor で照合する。
    private func isOutputFile(_ info: stat, url: URL) throws -> Bool {
        var destination = stat()
        guard fstat(output.fileDescriptor, &destination) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
        return ArchiveOwnedFile.hasAssignedInode(destination.st_ino)
            ? info.st_dev == destination.st_dev && info.st_ino == destination.st_ino
            : ArchiveOwnedFile.matches(url: url, descriptor: output.fileDescriptor)
    }

    // readlink は NUL を付けない。target を UTF-8 へ再符号化せず byte のまま返す。
    // PATH_MAX に収まらない target は読取中の変更とみなす。
    private static func symlinkTarget(at path: UnsafePointer<CChar>, url: URL) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count)
        guard count >= 0 else { throw WriterError.io(operation: "readlink", code: errno) }
        guard count < buffer.count else { throw WriterError.sourceChanged(url.path) }
        return Data(buffer.prefix(count))
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

    // format に対応する writer は一つだけ。予約済みの名前を渡し、成功した名前を appendedPaths に記録する。
    private func addReservedEntry(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?,
                                  owners: (UInt32, UInt32)?, hardLink: String?, read: (Int) throws -> Data) throws {
        if let tarWriter {
            try tarWriter.add(name: name, mode: mode, size: size, date: date, owners: owners, hardLink: hardLink, read: read)
        } else if let sevenZipWriter {
            try sevenZipWriter.add(name: name, mode: mode, size: size, date: date, read: read)
        } else if let lhaWriter {
            try lhaWriter.add(name: name, mode: mode, size: size, date: date, read: read)
        } else {
            try requireZipWriter().add(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners, read: read)
        }
        appendedPaths.append((name, mode.isDirectoryMode))
    }

    private static func linkSignature(_ info: stat) -> [Int64] {
        // 同じ inode が後から変更されていれば、古い payload への hard link に置き換えない。
        // Finder tag や LaunchServices の xattr 更新でも変わるため ctime は比較しない。
        [info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
         Int64(info.st_mode)]
    }

    // 結合文字が / と同じ grapheme に入ることがある。filesystem の区切りは byte なので utf8 で分ける。
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
        var attribution: AdditionAttribution { AdditionAttribution(index: index, addition: addition) }
    }

    private enum BatchPreparation {
        // pipeline に渡す項目。job は worker が読む通常ファイルにだけある。
        case entry(BatchEntry, FileJob?)
        // directory・項目窓を超える他 codec・ZipCrypto の通常ファイルは項目別の addDisk へ戻す。
        case fallBackToDisk(URL, DiskSignature)
    }

    // 呼出しの thread で lstat と出力自身の検査を行い、名前を予約して BatchEntry と worker の読取 job を作る。
    private func prepareBatchEntry(index: Int, addition: ArchiveAddition, expected: DiskSignature?,
                                   limiter: SourcePrefetchLimiter) throws -> BatchPreparation {
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
            try Self.testingBeforeLstat?(index, url)
            guard !cPath.isEmpty, cPath.withUnsafeBufferPointer({ lstat($0.baseAddress!, &info) }) == 0 else {
                throw WriterError.io(operation: "lstat", code: errno)
            }
            if let expected, !expected.matches(info) { throw WriterError.sourceChanged(url.path) }
            guard try !isOutputFile(info, url: url) else { throw WriterError.invalidPath("source contains output archive") }
            mode = info.st_mode & S_IFMT == S_IFLNK ? FileMode.defaultSymlink : UInt16(info.st_mode)
            date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            atime = Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec))
            owners = addition.ownerIDs.map { ($0.user, $0.group) }
                ?? (options.preserveOwnerIDs ? (info.st_uid, info.st_gid) : nil)
            let kind = info.st_mode & S_IFMT
            let threshold = zipWriter?.singleBlockLimit(name: addition.path, mode: mode, size: UInt64(max(0, info.st_size)))
                ?? DeflateBlock.size
            let stream = zipWriter?.supportsBatchStream(name: addition.path, mode: mode, size: UInt64(max(0, info.st_size))) == true
            if kind == S_IFDIR || (kind == S_IFREG && ((info.st_size > threshold && !stream) || zipWriter?.encryptsWithZipCrypto == true)) {
                return .fallBackToDisk(url, expected ?? DiskSignature(info))
            }
            if kind == S_IFLNK {
                inline = try cPath.withUnsafeBufferPointer { try Self.symlinkTarget(at: $0.baseAddress!, url: url) }
                size = UInt64(inline.count)
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
        let zip = try zipWriter?.makeEntry(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners)
        let entry = BatchEntry(index: index, addition: addition, name: name, mode: mode, size: size,
                               date: date, atime: atime, owners: owners, hardLink: hardLink, inline: inline, zip: zip)
        let job = mode.isRegularFileMode ? FileJob(index: index, addition: addition, path: cPath,
            expected: DiskSignature(info), size: Int(size), deflate: zip?.method == .deflate, limiter: limiter) : nil
        return .entry(entry, job)
    }

    // ZIP は deflate の pipeline、7z はその場で、tar / LHA は先読みの pipeline に渡す。どれも投入順に receive へ届く。
    private func submitBatchEntry(_ entry: BatchEntry, job: FileJob?,
                                  prefetch: OrderedChunkPipeline<FileJob, Prefetched, BatchEntry>?,
                                  emit: (ZipWriter.Tag, Prefetched?) throws -> Void,
                                  receive: (BatchEntry, Prefetched?) throws -> Void) throws {
        if let zipWriter {
            if let job, entry.size > zipWriter.singleBlockLimit(name: entry.name, mode: entry.mode, size: entry.size) {
                try zipWriter.submitLarge(entry.zip!, file: job, attribution: entry.attribution, emit: emit)
            } else {
                try zipWriter.submit(job, method: entry.zip!.method, attribution: entry.attribution, weight: entry.inputBytes, emit: emit)
            }
        } else if sevenZipWriter != nil {
            // LZMA2 の窓と I/O は重なる。追加の reader queue は小ファイルで encoder と競合する。
            try receive(entry, job.map { try $0.run { _ in throw WriterError.invalidState } })
        } else {
            try prefetch!.submit(job, tag: entry, weight: entry.inputBytes, emit: receive)
        }
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
        var blockProgress: CommitProgressMeter?
        func receive(_ entry: BatchEntry, _ result: Prefetched?) throws {
            do {
                try Task.checkCancellation()
                try additionEvent(.progress(index: entry.index, .init(completedBytes: 0, totalBytes: entry.inputBytes)), events)
                guard state == .writing, !additionsClosed else { throw WriterError.invalidState }
                let data = result?.data ?? entry.inline
                if let zip = entry.zip, let zipWriter {
                    if let spool = result?.spool {
                        try zipWriter.emitComplete(zip, spool: spool, crc: result!.crc, attribution: entry.attribution)
                    } else {
                        try zipWriter.emitComplete(zip, data: data, crc: result?.crc ?? updateCRC(0, data), attribution: entry.attribution)
                    }
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
                    try zipWriter?.flushOutput()
                }
                pendingBatch.removeFirst()
                do { try meter?.advance(entry.hardLink == nil ? entry.inputBytes : 0) }
                catch { throw AdditionEventFailure(underlying: error) }
                if entry.zip != nil, entry.size > zipWriter!.singleBlockLimit(name: entry.name, mode: entry.mode, size: entry.size) {
                    // stream worker の読取は通知を保持しない。完了した項目の順に従来の4 MiB間隔を再現する。
                    let progress = CommitProgressMeter(total: entry.inputBytes, progress: events.map { events in
                        { try additionEvent(.progress(index: entry.index, $0), events) }
                    })
                    while progress.completed < entry.inputBytes {
                        try progress.advance(min(CommitProgressMeter.notificationInterval, entry.inputBytes - progress.completed))
                    }
                    try progress.finish()
                } else {
                    try additionEvent(.progress(index: entry.index, .init(completedBytes: entry.inputBytes, totalBytes: entry.inputBytes)), events)
                }
                try additionEvent(.didFinish(index: entry.index), events)
            } catch { throw additionFailure(error, index: entry.index, addition: entry.addition) }
        }
        // ZIP の pipeline は投入順に emit するので、一括追加の tag の帰属先は待ちの先頭の項目。
        func emit(_ tag: ZipWriter.Tag, _ result: Prefetched?) throws {
            if let attribution = tag.attribution {
                guard let entry = pendingBatch.first, entry.index == attribution.index else { throw WriterError.invalidState }
                do {
                    try tag.verification?.verifySource()
                    if let count = tag.inputBytes {
                        if tag.entry != nil {
                            blockProgress = CommitProgressMeter(total: entry.inputBytes, progress: events.map { events in
                                { try additionEvent(.progress(index: entry.index, $0), events) }
                            })
                            try blockProgress!.start()
                        }
                        try zipWriter!.emitDeflate(tag, result)
                        try blockProgress!.advance(count)
                        if tag.crc != nil {
                            try zipWriter!.flushOutput()
                            appendedPaths.append((entry.name, false))
                            pendingBatch.removeFirst()
                            do { try meter?.advance(entry.inputBytes) }
                            catch { throw AdditionEventFailure(underlying: error) }
                            try blockProgress!.finish()
                            blockProgress = nil
                            try additionEvent(.didFinish(index: entry.index), events)
                        }
                    } else { try receive(entry, result) }
                } catch { throw additionFailure(error, index: entry.index, addition: entry.addition) }
            } else {
                try zipWriter!.emitDeflate(tag, result)
            }
        }
        func drain() throws {
            try zipWriter?.drain(emit: emit)
            try prefetch?.drain(emit: receive)
        }
        do {
            try performAddition {
                do {
                    for (index, addition) in additions.enumerated() {
                        try autoreleasepool {
                            // 後続の willStart を通知する前に窓の空きを作る。
                            try zipWriter?.waitForCapacity(emit: emit)
                            try prefetch?.waitForCapacity(emit: receive)
                            do {
                                try additionEvent(.willStart(index: index), events)
                                try Task.checkCancellation()
                                guard state == .writing, !additionsClosed else { throw WriterError.invalidState }
                                try validateOwnerIDs(addition.ownerIDs)
                                switch try prepareBatchEntry(index: index, addition: addition, expected: expected?[index], limiter: limiter) {
                                case let .fallBackToDisk(url, signature):
                                    try drain()
                                    var failedSource: URL?
                                    do {
                                        try addDisk(url, as: addition.path, ownerIDs: addition.ownerIDs, expected: signature,
                                                    progress: events.map { events in { try additionEvent(.progress(index: index, $0), events) } },
                                                    meter: meter, sourceFailure: { if failedSource == nil { failedSource = $0 } }) {
                                            try FileRead.readChunk($0.fileDescriptor, upTo: $1)
                                        }
                                        // ZIP の遅延 block の失敗も、この fallback 項目へ帰属させる。
                                        try zipWriter?.drain(emit: emit)
                                        try zipWriter?.flushOutput()
                                    } catch { throw additionFailure(error, index: index, addition: addition, sourceURL: failedSource) }
                                    try additionEvent(.didFinish(index: index), events)
                                case let .entry(entry, job):
                                    pendingBatch.append(entry)
                                    try submitBatchEntry(entry, job: job, prefetch: prefetch, emit: emit, receive: receive)
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
                    zipWriter?.abandonAndWait()
                    prefetch?.abandonAndWait()
                    pendingBatch.removeAll()
                    // 検証済みの前方の項目の write 失敗も、後方の source 失敗より優先する。
                    if let failed = error as? ArchiveAdditionError { try zipWriter?.flushOutput(ifBufferedBefore: failed.index) }
                    throw error
                }
            }
        } catch let error as AdditionEventFailure { throw error.underlying }
    }
}
