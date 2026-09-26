import Foundation
private import Darwin
public import KaitoKit

/// ZIP / ZIP64 の追加・削除・改名。生き残る entry は再圧縮しない。
/// thread-safe ではない。呼出側は同じ書庫への操作も直列化する。
/// add は作業ファイルに書き、削除・改名は予約する。commit は置換か指定した output を完成させる。
/// 失敗後は再利用できない。deinit は未 commit の作業ファイルを削除する。
public final class ArchiveUpdater: ArchiveEditing {
    private let url: URL
    private let options: WriterOptions
    private let outputURL: URL?
    private let sourceSnapshot: ArchiveSourceSnapshot?
    private let directory: ZipValidatedDirectory
    private let source: ZipUpdateSource
    private let layout: ZipUpdateLayout
    private let reader: ArchiveReader?
    private var removed: Set<Int> = []
    private var renamed: [Int: String] = [:]
    private var reencryptionRequested = false
    private var currentPassword: String?
    var afterRebuild: ((URL) throws -> Void)?
    private var pathReservations: EditPathReservations?
    var hasPathReservations: Bool { pathReservations != nil }
    private var indexedAppendCount = 0
    private var writerPathsNeedRefresh = false
    private var liveNameCheck: LiveNameCheck?
    private lazy var excluded = [Bool](repeating: false, count: Int(layout.count))
    private(set) var nameCheckScanCount = 0
    var writerUsesLiveNameCheck: Bool { writer?.existingPathCheck != nil }
    // 最終計画だけが使う取得境界。検証時と追加だけの commit は seam を通らない。
    lazy var recordLayout: (Int) throws -> ZipRecordLayout? = { [unowned self] in validatedLayout(at: $0) }
    @TaskLocal static var testingRandomBytes: (@Sendable (Int) throws -> Data)?
    @TaskLocal static var testingAppendedCorruption: (@Sendable (inout Data) -> Void)?
    @TaskLocal static var testingNameCheckBudget: Int?
    @TaskLocal static var testingNameCheckMinimumEntries: Int?

    @_spi(Testing) public enum CommitStrategy: Sendable, Equatable {
        case unchanged, appendOnly, inPlacePatch, rebuild, rebuildThenAppend, stagedRebuild
    }
    @_spi(Testing) public private(set) var lastCommitStrategy: CommitStrategy?

    public struct CommitProgress: Sendable, Equatable {
        /// 呼出しごとの仕事量。add は追加元の読取、finishAdditions は未出力の入力 byte。
        /// updater の commit は照合の読取・再暗号化の鍵導出も含み、事前の add は含まない。
        /// 単調に進み、成功時は 0 を含め total に一致する。ZIP commit は最終 total が変わり得る。
        /// 新しい追加・追加の終わり・rewriter commit の session は最初の total を固定する。
        public let completedBytes: UInt64
        public let totalBytes: UInt64
    }

    func validatedLayout(at index: Int) -> ZipRecordLayout? {
        directory.records.indices.contains(index) ? directory.records[index].layout : nil
    }

    static var readerOptions: ReaderOptions {
        ReaderOptions(limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max),
                      appleDoublePolicy: .expose)
    }
    private var writer: ArchiveWriter?
    private var replacementDirectory: URL?
    private var replacement: URL?
    private var ownedOutput: ArchiveOwnedFile?
    private var stagedSnapshot: ArchiveOwnedFile?
    private var outputHandle: FileHandle?
    private var appendStart: UInt64?
    private enum State { case adding, committed, failed }
    private var state = State.adding
    private var additionsClosed = false

    private init(url: URL, output: URL?, options: WriterOptions, source: ZipUpdateSource,
                 sourceSnapshot: ArchiveSourceSnapshot?, layout: ZipUpdateLayout, reader: ArchiveReader?,
                 directory: ZipValidatedDirectory) {
        self.url = url
        outputURL = output
        self.sourceSnapshot = sourceSnapshot
        self.directory = directory
        self.options = options
        self.source = source
        self.layout = layout
        self.reader = reader
    }

    deinit { cleanup() }

    /// open 時のゼロ始まり index に対応する名前。remove / rename に渡す index が
    /// 何を指すかを、呼出側が破壊的操作の前に照合するためのもの。
    /// 予約済みの削除・改名を反映せず、常に open 時の名前を返す。
    public var entryNames: [String] { reader?.entries.map(\.name) ?? [] }

    /// ZIP の編集用終端検査を通過した書庫の最小情報。entry 自体の検証結果ではない。
    public struct Probe: Sendable, Equatable {
        /// EOCD / ZIP64 EOCD が宣言する entry 数。
        public let entryCount: UInt64
    }

    /// KaitoKit の reader を作らず、単一 volume・正規の空書庫・編集用門番を検査する。
    /// SFX prefix / trailing data / 不正な CD offset / 曖昧な EOCD は open と同じ editingRefused、
    /// 終端の矛盾は同じ invalidArchive を返す。成功時はこれらの条件を満たす。
    /// CD の entry は解析しないため、呼出側は自身の検証済み reader の entry 数と
    /// entryCount が一致することを必ず確認してから、この結果を利用すること。
    /// CD 全体の walk と local record の対応検査は open だけが行う。probe は tail の読取量を維持する。
    /// entry 内容・読取制限の検査は reader の責務。同じ書庫への操作は直列化する。
    public static func probe(url: URL) throws -> Probe {
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        try source.checkUnchanged(at: url)
        return Probe(entryCount: layout.count)
    }

    /// output が nil なら原本を置換し、指定時は新規 output を完成させる（原本は読むだけ）。
    /// output は存在してはならず、親 directory は呼出側が用意する。
    /// 一時 snapshot は output の隣に置き、commit・失敗・破棄で消す。
    /// 成功した output は fsync・close 済みで mode 0600。属性の復元と公開は呼出側が行う。
    /// options.password は追加する通常ファイルを暗号化する。
    /// 既存 entry にも適用するときは reencryptExistingEntries(currentPassword:) を予約する。
    public static func open(url: URL, output: URL? = nil, options: WriterOptions = WriterOptions()) throws -> ArchiveUpdater {
        try options.validate(for: .zip)
        if let output { try ArchiveSourceSnapshot.validateOutput(output) }
        let snapshot = try output.map {
            try ArchiveSourceSnapshot(url: url, directory: $0.deletingLastPathComponent(), pathExtension: "zip")
        }
        let source = try snapshot?.source ?? ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let reader: ArchiveReader?
        let directory: ZipValidatedDirectory
        if layout.count == 0 {
            reader = nil
            directory = ZipValidatedDirectory(bytes: Data(), records: [])
        } else {
            let parsed = try ArchiveReader.open(source: source, options: readerOptions)
            guard parsed.format == .zip, UInt64(parsed.entries.count) == layout.count else {
                throw UpdaterError.invalidArchive("KaitoKit の entry 数と EOCD が一致しません")
            }
            directory = try ZipCentralDirectory.validate(source: source, reader: parsed,
                centralOffset: layout.centralOffset, centralSize: layout.centralSize)
            reader = parsed
        }
        if let snapshot { try snapshot.checkUnchanged() }
        else { try source.checkUnchanged(at: url) }
        return ArchiveUpdater(url: url, output: output, options: options, source: source,
                              sourceSnapshot: snapshot, layout: layout, reader: reader, directory: directory)
    }

    public func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        try performAddition { try preparedWriter().add(additions, events: events) }
    }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?,
                    progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try performAddition {
            try preparedWriter().add(contentsOf: url, as: path, ownerIDs: ownerIDs, progress: progress)
        }
    }

    public func finishAdditions(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try perform {
            additionsClosed = true
            if let writer { try writer.finishAdditions(progress: progress) }
            else {
                let meter = CommitProgressMeter(total: 0, progress: progress)
                try meter.start()
                try meter.finish()
            }
        }
    }

    private func performAddition(_ body: () throws -> Void) throws {
        guard !additionsClosed else { throw UpdaterError.invalidState }
        try perform(body)
    }

    public func add(contentsOf url: URL, as path: String) throws {
        try performAddition { try preparedWriter().add(contentsOf: url, as: path) }
    }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition { try preparedWriter().add(contentsOf: url, as: path, ownerIDs: ownerIDs) }
    }

    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try performAddition {
            try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions)
        }
    }

    public func addDirectory(_ path: String) throws {
        try performAddition { try preparedWriter().addDirectory(path) }
    }

    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition { try preparedWriter().addDirectory(path, modificationDate: modificationDate, ownerIDs: ownerIDs) }
    }

    /// commit 時に既存 entry の暗号化を options にそろえる。圧縮データは作り直さない。
    /// 通常ファイルは password / zipEncryption（AES-256）、directory と symlink は平文にする。
    /// 同じ方式で password の UTF-8 byte 列が同じ entry は byte のまま運び、password は検証しない。
    /// 全暗号化 entry を currentPassword で検証済みであることは呼出側の責務。
    /// 追加 entry は対象外。変換が 0 件なら出力は変わらない。remove / rename / add との順序は問わない。
    /// currentPassword は入力の復号用。一度だけ呼べる。進捗は commit(progress:) に含まれる。
    public func reencryptExistingEntries(currentPassword: String?) throws {
        try perform {
            guard !reencryptionRequested else { throw UpdaterError.invalidState }
            reencryptionRequested = true
            self.currentPassword = currentPassword
        }
    }

    /// open 時のゼロ始まり index を削除予約する。重複指定は一度だけ削除する。
    /// directory の子孫は暗黙に削除しない。予約後も他 entry の index は変わらない。
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            for index in indices { try validateIndex(index) }
            indexAppendedPaths()
            for index in indices where !removed.contains(index) {
                let entry = reader!.entries[index]
                pathReservations?.remove(renamed[index] ?? entry.name, directory: entry.kind == .directory)
                removed.insert(index)
                renamed.removeValue(forKey: index)
                excluded[index] = true
            }
            writerPathsNeedRefresh = true
        }
    }

    /// open 時の index を改名予約する。新しい名前は UTF-8 / NFC、directory は末尾 /。
    /// 削除済み entry は指定できず、子孫の改名や symlink target の変更は行わない。
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index), let reader else { throw UpdaterError.invalidEntryIndex(index) }
            let directory = reader.entries[index].kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .zip)
            if pathReservations == nil, canScanNames {
                try checkLiveName(name, directory: directory, mode: .reservations, excluding: index)
            } else {
                let pathReservations = reservations()
                indexAppendedPaths()
                pathReservations.remove(renamed[index] ?? reader.entries[index].name, directory: directory)
                try pathReservations.validate(name, directory: directory)
                pathReservations.insert(name, directory: directory)
            }
            renamed[index] = name
            excluded[index] = true
            writerPathsNeedRefresh = true
        }
    }

    private func validateIndex(_ index: Int) throws {
        guard index >= 0, UInt64(index) < layout.count else { throw UpdaterError.invalidEntryIndex(index) }
    }

    private var existingPaths: [(String, Bool)] {
        let entries = reader?.entries ?? []
        if !removed.isEmpty {
            return entries.filter { !removed.contains($0.index) }
                .map { (renamed[$0.index] ?? $0.name, $0.kind == .directory) }
        }
        // 少数の改名で、全件の dictionary 検索を繰り返さない。
        var paths = entries.map { ($0.name, $0.kind == .directory) }
        for (index, name) in renamed { paths[index].0 = name }
        return paths
    }

    private var canScanNames: Bool {
        Int(layout.count) >= (Self.testingNameCheckMinimumEntries ?? 2_048)
            && nameCheckScanCount < (Self.testingNameCheckBudget ?? 4)
    }

    private func checkLiveName(_ name: String, directory: Bool, mode: LiveNameCheck.Mode,
                               excluding index: Int? = nil) throws {
        if liveNameCheck == nil {
            let entries = reader?.entries ?? []
            liveNameCheck = LiveNameCheck(count: entries.count) { index in
                let entry = entries[index]
                return (entry.name, entry.kind == .directory)
            }
        }
        nameCheckScanCount += 1
        try liveNameCheck!.validate(name, directory: directory, mode: mode, excluded: excluded,
                                   excluding: index, renamed: renamed, appended: writer?.appendedPaths ?? [])
    }

    private func reservations() -> EditPathReservations {
        if let pathReservations { return pathReservations }
        let paths = writer?.appendedPaths ?? []
        let reservations = EditPathReservations(existingPaths + paths)
        pathReservations = reservations
        indexedAppendCount = paths.count
        return reservations
    }

    private func indexAppendedPaths() {
        guard let writer, let pathReservations else { return }
        for (path, directory) in writer.appendedPaths.dropFirst(indexedAppendCount) {
            pathReservations.insert(path, directory: directory)
        }
        indexedAppendCount = writer.appendedPaths.count
    }

    /// 終端を同期し、置換か output の完成を行う。成功後の再呼出しは no-op。
    /// 置換後の metadata 復元でエラーになった場合、内容の置換は既に完了している。
    public func commit() throws { try commit(progress: nil) }

    /// progress はこの呼出しの thread で同期的に呼び、呼出しの外に保持しない。
    /// throw は取消しと同じく、作業ファイルを消して instance を失敗状態にする。
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        if state == .committed { return }
        try perform {
            try checkUnchanged()
            let reencryption = try reencryptionRequested ? ZipReencryption.plan(reader: reader, directory: directory,
                removed: removed, options: options, currentPassword: currentPassword) : nil
            let rebuild = !removed.isEmpty || !renamed.isEmpty || reencryption != nil
            let appended = try writer?.drainAppendedRecords()
            var verification: (ZipRebuild.Plan, ZipCommitMeter)?
            if rebuild, let reader {
                try prepareClone()
                let written = appended.map { appendStart!..<$0.end }
                let plan = try ZipRebuild.plan(source: source, layout: layout, reader: reader, directory: directory,
                    removed: removed, renamed: renamed, writtenRange: written,
                    appended: appended?.entries ?? [], reencryption: reencryption, recordLayout: recordLayout)
                var stagedSource: ZipUpdateSource?
                if let written, plan.end != written.lowerBound {
                    let parent = outputURL?.deletingLastPathComponent() ?? replacementDirectory!
                    let staged = parent.appendingPathComponent(".gyoshuku-staged-\(UUID().uuidString).zip")
                    try FileManager.default.copyItem(at: replacement!, to: staged)
                    stagedSnapshot = try ArchiveOwnedFile(url: staged)
                    stagedSource = try ZipUpdateSource(url: staged)
                    lastCommitStrategy = .stagedRebuild
                } else if appended != nil { lastCommitStrategy = .rebuildThenAppend }
                else { lastCommitStrategy = plan.inPlace ? .inPlacePatch : .rebuild }
                let movedBytes = stagedSource == nil ? 0 : written!.upperBound - written!.lowerBound
                let total = try checkedAdd(checkedAdd(plan.totalBytes, movedBytes), reencryption?.work ?? 0)
                try Task.checkCancellation()
                try progress?(.init(completedBytes: 0, totalBytes: total))
                var engine = ZipCopyEngine(descriptor: outputHandle!.fileDescriptor, totalBytes: total)
                try ZipRebuild.execute(plan, source: source, directory: directory, layout: layout,
                    stagedSource: stagedSource, writtenRange: written, reencryption: reencryption, engine: &engine, progress: progress)
                if let appended, let written {
                    if let corrupt = Self.testingAppendedCorruption, let first = appended.entries.first {
                        var bytes = try ZipAppendedRecordCheck.read(outputHandle!.fileDescriptor, at: plan.end, count: first.local().count)
                        corrupt(&bytes)
                        try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(outputHandle!.fileDescriptor, bytes: $0, at: plan.end) }
                    }
                    try ZipAppendedRecordCheck.check(descriptor: outputHandle!.fileDescriptor, entries: appended.entries,
                        start: plan.end, recordBase: layout.centralOffset,
                        blockLength: written.upperBound - written.lowerBound, centralOffset: plan.centralOffset)
                }
                try Task.checkCancellation()
                if !plan.inPlace { try outputHandle!.truncate(atOffset: plan.finalEnd) }
                try outputHandle!.synchronize()
                if reencryption != nil { verification = (plan, engine.meter) }
                else { try engine.meter.finish(progress: progress) }
            } else if let writer, let appended {
                lastCommitStrategy = .appendOnly
                var size = layout.centralSize
                for entry in appended.entries { size = try checkedAdd(size, UInt64(entry.central().count)) }
                let end = try ZipRecords.end(count: checkedAdd(layout.count, UInt64(appended.entries.count)),
                    centralSize: size, centralOffset: appended.end, comment: layout.comment)
                let total = try checkedAdd(size, UInt64(end.count))
                try Task.checkCancellation()
                try progress?(.init(completedBytes: 0, totalBytes: total))
                var meter = ZipCommitMeter(totalBytes: total)
                try writer.finish(existingCount: layout.count, comment: layout.comment,
                                  progress: { _, count in try meter.wrote(count, progress: progress) }) { emit in
                    for cursor in stride(from: 0, to: directory.bytes.count, by: 4 * 1024 * 1024) {
                        try emit(directory.bytes.subdata(in: cursor..<min(cursor + 4 * 1024 * 1024, directory.bytes.count)))
                    }
                }
                outputHandle = nil
                try meter.finish(progress: progress)
            } else {
                lastCommitStrategy = .unchanged
                if outputURL != nil { try prepareClone() }
                try Task.checkCancellation()
                try progress?(.init(completedBytes: 0, totalBytes: 0))
                try outputHandle?.synchronize()
                try progress?(.init(completedBytes: 0, totalBytes: 0))
            }
            self.writer = nil
            try outputHandle?.close()
            outputHandle = nil
            if let reencryption, let (plan, pendingMeter) = verification {
                var meter = pendingMeter
                do { try afterRebuild?(replacement!) }
                catch is CancellationError { throw CancellationError() }
                catch { throw UpdaterError.reencryptionFailed(index: -1, name: "", reason: "出力の検証を開始できません") }
                try reencryption.verify(url: replacement!, plan: plan, directory: directory, renamed: renamed,
                    appended: appended?.entries ?? [], meter: &meter, progress: progress)
                guard meter.completedBytes == meter.totalBytes else {
                    throw UpdaterError.reencryptionFailed(index: -1, name: "", reason: "変換の仕事量が計画と一致しません")
                }
                try meter.finish(progress: progress)
            }
            currentPassword = nil
            try Task.checkCancellation()
            if let replacement {
                try checkOutputIdentity()
                if outputURL != nil {
                    try checkUnchanged()
                    try Task.checkCancellation()
                } else {
                    let quarantine = try readQuarantine()
                    try checkUnchanged()
                    try Task.checkCancellation()
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
                    try FileManager.default.setAttributes([.posixPermissions: source.mode], ofItemAtPath: url.path)
                    if let quarantine {
                        let status = quarantine.withUnsafeBytes {
                            setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                        }
                        guard status == 0 else { throw WriterError.io(operation: "restore quarantine", code: errno) }
                    }
                }
            }
            state = .committed
            ownedOutput = nil
            cleanup()
        }
    }

    private func checkUnchanged() throws {
        if let sourceSnapshot { try sourceSnapshot.checkUnchanged() }
        else { try source.checkUnchanged(at: url) }
    }

    private func checkOutputIdentity() throws {
        guard let ownedOutput else { return }
        var info = stat()
        guard lstat(ownedOutput.url.path, &info) == 0, ownedOutput.identity.matchesInode(info) else {
            throw UpdaterError.sourceChanged
        }
    }

    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh, writer.existingPathCheck == nil {
                writer.replaceExistingPaths(existingPaths)
                writerPathsNeedRefresh = false
            }
            return writer
        }
        try prepareClone()
        var position = layout.centralOffset
        if !removed.isEmpty || !renamed.isEmpty {
            position = (try? ZipRebuild.predictedEnd(source: source, directory: directory, removed: removed, renamed: renamed)) ?? position
        }
        appendStart = position
        let hook = Self.testingRandomBytes
        let writer = ArchiveWriter(output: outputHandle!, url: replacement!,
            identity: (ownedOutput!.identity.device, ownedOutput!.identity.inode), format: .zip, options: options,
            zipSalt: { try hook?(16) ?? EncryptionPrimitives.random(count: 16) })
        self.writer = writer
        if canScanNames {
            try writer.prepareAppend(at: position, existingPaths: [], recordBase: layout.centralOffset)
            writer.existingPathCheck = { [unowned self] name, directory in
                if self.canScanNames {
                    try self.checkLiveName(name, directory: directory, mode: .writer)
                } else {
                    self.writer!.replaceExistingPaths(self.existingPaths)
                    self.writer!.existingPathCheck = nil
                    self.writerPathsNeedRefresh = false
                }
            }
        } else {
            try writer.prepareAppend(at: position, existingPaths: existingPaths, recordBase: layout.centralOffset)
        }
        writerPathsNeedRefresh = false
        return writer
    }

    private func prepareClone() throws {
        if replacement != nil { try checkOutputIdentity(); return }
        try Task.checkCancellation()
        try checkUnchanged()
        let clone: URL
        if let outputURL { clone = outputURL }
        else {
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                        appropriateFor: url, create: true)
            replacementDirectory = directory
            clone = directory.appendingPathComponent("archive.zip")
        }
        if let sourceSnapshot, sourceSnapshot.snapshot != nil {
            guard fclonefileat(source.descriptor, AT_FDCWD, clone.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                throw WriterError.io(operation: "clone output", code: errno)
            }
        } else { try FileManager.default.copyItem(at: url, to: clone) }
        replacement = clone
        ownedOutput = try ArchiveOwnedFile(url: clone)
        try checkUnchanged()
        let fd = Darwin.open(clone.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WriterError.io(operation: "open clone", code: errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, ownedOutput!.identity.matchesInode(info) else { throw UpdaterError.sourceChanged }
        guard fchmod(fd, 0o600) == 0 else { throw WriterError.io(operation: "chmod clone", code: errno) }
        if info.st_flags != 0, fchflags(fd, 0) != 0 { throw WriterError.io(operation: "clear output flags", code: errno) }
        let writable = Darwin.open(clone.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard writable >= 0 else { throw WriterError.io(operation: "open output", code: errno) }
        let handle = FileHandle(fileDescriptor: writable, closeOnDealloc: true)
        guard fstat(writable, &info) == 0, ownedOutput!.identity.matchesInode(info) else { throw UpdaterError.sourceChanged }
        try checkOutputIdentity()
        outputHandle = handle
    }

    private func readQuarantine() throws -> Data? {
        let count = fgetxattr(source.descriptor, "com.apple.quarantine", nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0 else { throw WriterError.io(operation: "read quarantine size", code: errno) }
        var value = Data(count: count)
        let actual = value.withUnsafeMutableBytes {
            fgetxattr(source.descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        guard actual == count else { throw WriterError.io(operation: "read quarantine", code: errno) }
        return value
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .adding else { throw UpdaterError.invalidState }
        do { try body() } catch {
            state = .failed
            cleanup()
            throw error
        }
    }

    private func cleanup() {
        currentPassword = nil
        writer = nil
        try? outputHandle?.close()
        outputHandle = nil
        ownedOutput?.remove()
        ownedOutput = nil
        stagedSnapshot?.remove()
        stagedSnapshot = nil
        sourceSnapshot?.cleanup()
        if let replacementDirectory { try? FileManager.default.removeItem(at: replacementDirectory) }
        replacementDirectory = nil
        replacement = nil
    }
}

extension ArchiveUpdater: ArchiveReencrypting {}
