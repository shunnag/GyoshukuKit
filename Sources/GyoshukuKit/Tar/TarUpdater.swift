import Foundation
internal import KaitoKit

/// 非圧縮 tar を別の新規ファイルへ編集する。原本と運ぶ member の byte を保つ。
/// 名前の衝突は正規化して検査するが、改名しない member の名前の byte は変えない。
/// thread-safe ではない。同じ instance の操作は呼出側で直列化する。
/// requiresRewrite は open だけが返す。失敗後は再利用できず、未完了の出力は削除する。
public final class TarUpdater: ArchiveEditing {
    @_spi(Testing) public enum CommitStrategy: Sendable, Equatable {
        case unchanged, inPlacePatch, appendOnly, splice, sequential, relocatedAppend
    }
    @_spi(Testing) public private(set) var lastCommitStrategy: CommitStrategy?
    @_spi(Testing) @TaskLocal public static var testingDisablesClone = false
    enum Fault: Sendable { case flipWrittenByte(UInt64), shiftSourceSegment, dropTerminatorBlock, corruptWrittenHeader }
    @TaskLocal static var testingFault: Fault?

    private let snapshot: ArchiveSourceSnapshot
    private let output: URL
    private let options: WriterOptions
    private let reader: ArchiveReader
    private let layout: TarLayout
    private let ledger: EntryEditLedger
    private let rawNames: [Data]
    private let hardLinkTargets: [Int: Int]
    private let dataTargets: [Int: Int]
    private let destination: SegmentedArchiveOutput
    private var writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?
    private var appendStart: UInt64?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private var additionsClosed = false

    /// 常に open 時の名前。予約や追加は反映しない。
    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(snapshot: ArchiveSourceSnapshot, output: URL, options: WriterOptions, reader: ArchiveReader,
                 layout: TarLayout, names: [String], hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        self.snapshot = snapshot
        self.output = output
        self.options = options
        self.reader = reader
        self.layout = layout
        ledger = EntryEditLedger(names: names, entries: reader.entries)
        rawNames = reader.entries.map { Data($0.rawName.bytes) }
        self.hardLinkTargets = hardLinkTargets
        self.dataTargets = dataTargets
        destination = SegmentedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "tar",
                                           sequential: Self.testingDisablesClone)
    }
    deinit { if state != .committed { cleanup() } }

    /// output は既存でない file URL。その親 directory は呼出側で作成する。
    /// .beginning / .reset は原本の内容を変更せず requiresRewrite を返す。
    public static func open(url: URL, output: URL, options: WriterOptions = WriterOptions()) throws -> TarUpdater {
        try options.validate(for: .tar)
        guard options.additionPlacement == .end else { throw TarUpdaterError.requiresRewrite(reason: "additionPlacement") }
        guard options.carriedTarOwnerIDs == .keep else { throw TarUpdaterError.requiresRewrite(reason: "carriedTarOwnerIDs") }
        guard ArchiveVolumeSet.parse(fileName: url.lastPathComponent) == nil else {
            throw TarUpdaterError.requiresRewrite(reason: "split volume name")
        }
        try ArchiveSourceSnapshot.validateOutput(output)
        try Task.checkCancellation()
        let snapshot = try ArchiveSourceSnapshot(url: url, directory: output.deletingLastPathComponent(),
                                                 pathExtension: "tar", disablesClone: testingDisablesClone)
        let reader = try ArchiveReader.open(source: snapshot.source, sourceURL: url, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        guard reader.format == .tar else { throw UpdaterError.invalidArchive("非圧縮 tar ではありません") }
        let representable = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: .tar, reader: reader)
        let layout = try TarLayout.scan(source: snapshot.source, length: snapshot.source.length, entries: reader.entries,
                                        nameEncoding: reader.nameEncoding, hardLinkTargets: representable.hardLinkTargets,
                                        dataTargets: representable.dataTargets)
        try snapshot.checkUnchanged()
        return TarUpdater(snapshot: snapshot, output: output, options: options, reader: reader, layout: layout,
                          names: representable.names, hardLinkTargets: representable.hardLinkTargets, dataTargets: representable.dataTargets)
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
            let meter = CommitProgressMeter(total: 0, progress: progress)
            try meter.start()
            try meter.finish()
        }
    }

    private func performAddition(_ body: () throws -> Void) throws {
        guard !additionsClosed else { throw UpdaterError.invalidState }
        try perform(body)
    }

    public func add(contentsOf url: URL, as path: String) throws { try add(contentsOf: url, as: path, ownerIDs: nil) }
    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition { try preparedWriter().add(contentsOf: url, as: path, ownerIDs: ownerIDs) }
    }
    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try performAddition { try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions) }
    }
    public func addDirectory(_ path: String) throws { try addDirectory(path, modificationDate: nil, ownerIDs: nil) }
    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition { try preparedWriter().addDirectory(path, modificationDate: modificationDate, ownerIDs: ownerIDs) }
    }
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            try ledger.remove(indices, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try ledger.rename(index, to: path, format: .tar, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }
    public func commit() throws { try commit(progress: nil) }

    /// total は計画後に固定し、書く byte と V2/V5 の照合で読む byte を数える。
    /// 同期 callback の throw と再入は commit を失敗させる。成功後の再呼出しは no-op。
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        if state == .committed { return }
        try perform {
            state = .committing
            try snapshot.checkUnchanged()
            let appendedPaths = writer?.appendedPaths ?? []
            let appendedEnd = try writer?.endAppendedMembers()
            writer = nil
            let appended = appendedEnd.map { appendStart!..<$0 }
            let plan = try makePlan(additionLength: appended?.byteLength ?? 0)
            let prefix: [OutputSegment] = plan.isChanged ? plan.prefix : [.source(0..<snapshot.source.length)]
            let finalLength = plan.isChanged ? try checkedAdd(plan.membersEnd,
                checkedAdd(appended?.byteLength ?? 0, UInt64(plan.terminal.count))) : snapshot.source.length
            let outputPlan = SegmentCommitPlan(prefix: prefix, appended: appended, terminal: plan.terminal,
                finalLength: finalLength, formatVerificationUnits: UInt64(plan.boundaries.count) * TarSelfCheck.boundaryUnits)
            let meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: { update in
                try progress?(update)
                guard self.state == .committing else { throw UpdaterError.invalidState }
            })
            try Task.checkCancellation()
            try meter.start()
            let fault = Self.testingFault.map { TarSelfCheck.faultAction($0, plan: plan, finalLength: finalLength) }
            let strategy = try SegmentedArchiveOutput.$testingBeforeSynchronize.withValue(fault) {
                try destination.commit(outputPlan, meter: meter) { fd, advance in
                    try TarSelfCheck.verify(plan: plan, appendedPaths: appendedPaths, additionLength: appended?.byteLength ?? 0,
                                            finalLength: finalLength, descriptor: fd, source: self.snapshot.source,
                                            layout: self.layout, advance: advance)
                }
            }
            try meter.finish()
            try Task.checkCancellation()
            lastCommitStrategy = CommitStrategy(strategy, appendWasSplice: !ledger.removed.isEmpty || !plan.changed.isEmpty)
            state = .committed
        }
    }

    private func makePlan(additionLength: UInt64 = 0) throws -> TarEditPlan {
        do { return try TarEditPlan.make(layout: layout, source: snapshot.source, names: ledger.names, rawNames: rawNames,
                             hardLinkTargets: hardLinkTargets, dataTargets: dataTargets, removed: ledger.removed,
                             renamed: ledger.renamed, additionLength: additionLength) }
        catch TarUpdaterError.requiresRewrite { throw UpdaterError.sourceChanged }
    }
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh { writer.replaceExistingPaths(ledger.existingPaths); writerPathsNeedRefresh = false }
            return writer
        }
        let plan = try makePlan()
        let handle = try destination.beginAppend(at: plan.membersEnd, prefix: plan.prefix)
        let writer = try ArchiveWriter.tarAppend(output: handle, url: output, at: plan.membersEnd,
                                                 options: options, existingPaths: ledger.existingPaths)
        self.writer = writer; appendStart = plan.membersEnd; writerPathsNeedRefresh = false
        return writer
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .adding else {
            if state == .committing { state = .failed }
            throw UpdaterError.invalidState
        }
        do { try Task.checkCancellation(); try body() }
        catch { state = .failed; cleanup(); throw error }
    }
    private func cleanup() { writer = nil; destination.discard() }
}

extension TarUpdater.CommitStrategy {
    /// 共有 engine の戦略を tar の戦略に写す。engine には追加だけに見える commit でも、削除や header 変更を含めば splice。
    init(_ shared: SegmentCommitStrategy, appendWasSplice: Bool) {
        switch shared {
        case .unchanged: self = .unchanged
        case .inPlacePatch: self = .inPlacePatch
        case .appendOnly: self = appendWasSplice ? .splice : .appendOnly
        case .splice: self = .splice
        case .sequential: self = .sequential
        case .relocatedAppend: self = .relocatedAppend
        }
    }
}
