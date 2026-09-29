import Foundation
public import KaitoKit

/// 7z の更新。原本を変更せず、運ぶ folder の圧縮 byte と file の生値を保つ。
/// thread-safe ではない。失敗後は再利用できず、自分の作業ファイルだけを削除する。
/// 公開前の KaitoKit による再解析・計画照合と、出力属性の復元は呼出側の責務。
public final class SevenZipUpdater: ArchiveReencrypting {
    @_spi(Testing) public enum CommitStrategy: Sendable, Equatable {
        case unchanged, headerOnly, appendOnly, compacted, reencoded, reencrypted, sequential, relocatedAppend
    }
    @_spi(Testing) public private(set) var lastCommitStrategy: CommitStrategy?
    @_spi(Testing) public private(set) var lastCommitStatistics: SevenZipCommitStatistics?
    @_spi(Testing) @TaskLocal public static var testingDisablesClone = false
    enum Fault: Sendable {
        case flipMovedPackByte, flipAppendedPackByte, flipReencodedPackByte, flipConvertedPackByte
        case corruptSerializedName, dropLastPackFromModel
    }
    @TaskLocal static var testingFault: Fault?
    @TaskLocal static var testingLayoutMismatch = false

    let snapshot: ArchiveSourceSnapshot
    let output: URL
    let options: WriterOptions
    let reader: ArchiveReader
    let model: SevenZipEditModel
    private let ledger: EntryEditLedger
    let filesByFolder: [[Int]]
    let destination: SplicedArchiveOutput
    private let headerPassword: String?
    private(set) var reencrypt = false
    private var currentPassword: String?
    private var encryptors: SevenZipAESEncryptor.Factory
    private var writerPathsNeedRefresh = false
    var writer: ArchiveWriter?
    private(set) var appendStart: UInt64?
    var reencoded: [Int: SevenZipReencodedFolder] = [:]
    var conversions: [Int: SevenZipFolderConversion] = [:]
    var passwordChecked: Set<Int> = []
    enum State { case adding, committing, committed, failed }
    private(set) var state = State.adding
    private var additionsClosed = false

    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(snapshot: ArchiveSourceSnapshot, output: URL, options: WriterOptions, reader: ArchiveReader,
                 model: SevenZipEditModel, names: [String], password: String?) {
        self.snapshot = snapshot; self.output = output; self.options = options; self.reader = reader
        self.model = model; ledger = EntryEditLedger(names: names, entries: reader.entries)
        filesByFolder = model.filesByFolder; headerPassword = password
        encryptors = SevenZipAESEncryptor.Factory(password: options.password)
        destination = SplicedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "7z", sequential: Self.testingDisablesClone)
    }
    deinit { if state != .committed { cleanup() } }

    public static func assess(reader: ArchiveReader) -> SevenZipAssessment? {
        guard let model = SevenZipEditModel.read(reader) else { return nil }
        let reason = model.rewriteReason(entries: reader.entries) ?? (testingLayoutMismatch ? "layout mismatch" : nil)
        return SevenZipAssessment(updatable: reason == nil, reason: reason,
            hasSolidFolders: model.folders.contains { $0.substreamIndices.count > 1 },
            canReencrypt: reason == nil && model.folders.allSatisfy(\.canReencrypt))
    }

    public static func open(url: URL, password: String? = nil, output: URL,
                            options: WriterOptions = WriterOptions()) throws -> SevenZipUpdater {
        try options.validate(for: .sevenZip)
        guard options.additionPlacement == .end else { throw UpdaterRouteError.requiresRewrite(reason: "additionPlacement") }
        guard ArchiveVolumeSet.parse(fileName: url.lastPathComponent) == nil else {
            throw UpdaterRouteError.requiresRewrite(reason: "split volume name")
        }
        try ArchiveSourceSnapshot.validateOutput(output)
        try Task.checkCancellation()
        let snapshot = try ArchiveSourceSnapshot(url: url, directory: output.deletingLastPathComponent(),
                                                 pathExtension: "7z", disablesClone: testingDisablesClone)
        let reader = try ArchiveReader.open(source: snapshot.source, sourceURL: url,
                                           options: SevenZipEditModel.readerOptions(password: password))
        guard reader.format == .sevenZip else { throw UpdaterError.invalidArchive("7z ではありません") }
        let representable = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: .sevenZip, reader: reader)
        guard let model = SevenZipEditModel.read(reader) else { throw UpdaterRouteError.requiresRewrite(reason: "no 7z editing snapshot") }
        if let reason = model.rewriteReason(entries: reader.entries) { throw UpdaterRouteError.requiresRewrite(reason: reason) }
        if testingLayoutMismatch { throw UpdaterRouteError.requiresRewrite(reason: "layout mismatch") }
        try snapshot.checkUnchanged()
        return SevenZipUpdater(snapshot: snapshot, output: output, options: options, reader: reader,
                               model: model, names: representable.names, password: password)
    }

    public func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        guard !additions.isEmpty else { return }
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

    public func add(contentsOf url: URL, as path: String) throws { try add(contentsOf: url, as: path, ownerIDs: nil) }
    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        guard !additionsClosed else { throw UpdaterError.invalidState }
        guard ownerIDs == nil else { throw WriterError.unsupportedOption("ownerIDs") }
        try performAddition { try preparedWriter().add(contentsOf: url, as: path) }
    }
    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try performAddition { try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions) }
    }
    public func addDirectory(_ path: String) throws { try addDirectory(path, modificationDate: nil, ownerIDs: nil) }
    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        guard !additionsClosed else { throw UpdaterError.invalidState }
        guard ownerIDs == nil else { throw WriterError.unsupportedOption("ownerIDs") }
        try performAddition { try preparedWriter().addDirectory(path, modificationDate: modificationDate, ownerIDs: nil) }
    }
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            try ledger.remove(indices, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try ledger.rename(index, to: path, format: .sevenZip, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }
    public func reencryptExistingEntries(currentPassword: String?) throws {
        try perform {
            guard !reencrypt else { throw UpdaterError.invalidState }
            for (index, folder) in model.folders.enumerated() where !folder.canReencrypt {
                let file = filesByFolder[index].first ?? 0
                throw UpdaterError.reencryptionFailed(index: file, name: reader.entries.indices.contains(file) ? reader.entries[file].name : "",
                                                      reason: "7z の folder の形のため暗号化を変更できません")
            }
            reencrypt = true; self.currentPassword = currentPassword; reader.password = currentPassword
            reencoded.removeAll(); conversions.removeAll(); passwordChecked.removeAll()
        }
    }
    public func commit() throws { try commit(progress: nil) }
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        if state == .committed { return }
        try perform {
            state = .committing
            let result = try executeCommit(progress: progress)
            lastCommitStrategy = result.strategy
            lastCommitStatistics = result
            state = .committed
        }
    }

    func makePlan(additions: Int = 0) -> SevenZipEditPlan {
        SevenZipEditPlan.make(model: model, filesByFolder: filesByFolder, names: ledger.names, removed: ledger.removed,
            renamed: ledger.renamed, additions: additions, reencrypt: reencrypt, currentPassword: currentPassword,
            headerPassword: headerPassword, options: options)
    }
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh { writer.replaceExistingPaths(ledger.existingPaths); writerPathsNeedRefresh = false }
            return writer
        }
        let plan = makePlan()
        let prefix: [SplicedSegment]
        if destination.isCloneMode { prefix = try preliminaryPrefix(plan) }
        else {
            try prepareConversions(plan, toScratch: true)
            try prepareReencodings(plan, advance: { _ in })
            prefix = try makePrefix(plan)
        }
        let offset = prefix.reduce(UInt64(0)) { $0 + $1.length }
        let handle = try destination.beginAppend(at: offset, prefix: prefix)
        let writer = try ArchiveWriter.sevenZipAppend(output: handle, url: output, at: offset,
                                                     options: options, existingPaths: ledger.existingPaths)
        self.writer = writer; appendStart = offset; writerPathsNeedRefresh = false
        return writer
    }
    /// enabled なら options.password の encryptor。password が無ければ invalidOption("password")。
    func makeEncryptor(enabled: Bool) throws -> SevenZipAESEncryptor? {
        guard enabled else { return nil }
        guard let aes = try encryptors.make() else { throw WriterError.invalidOption("password") }
        return aes
    }
    private func perform(_ body: () throws -> Void) throws {
        guard state == .adding else {
            if state == .committing { state = .failed }
            throw UpdaterError.invalidState
        }
        do { try Task.checkCancellation(); try body() }
        catch { state = .failed; cleanup(); throw error }
    }
    private func cleanup() { writer = nil; destination.discard(); snapshot.cleanup() }
}
