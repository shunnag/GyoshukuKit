import Foundation
public import KaitoKit

/// LHA の追加・削除・改名。運ぶ member の byte を保ち、追加は末尾へ書く。thread-safe ではない。
/// 原本は読むだけで、output を新しく作る。mode・xattr・作成日の復元と公開は呼出側の責務。
/// open は WriterError、KaitoError、UpdaterError.invalidArchive、RewriterError.unrepresentable、
/// UpdaterRouteError.requiresRewrite を返し得る。失敗後は再利用できず、自分の作業ファイルを削除する。
public final class LHAUpdater: ArchiveEditing {
    @_spi(Testing) public enum CommitStrategy: Sendable, Equatable {
        case unchanged, inPlacePatch, appendOnly, splice, sequential, relocatedAppend
    }
    @_spi(Testing) public private(set) var lastCommitStrategy: CommitStrategy?
    @_spi(Testing) @TaskLocal public static var testingDisablesClone = false
    enum Fault: Sendable {
        case flipWrittenByte(UInt64), shiftSourceSegment, dropTerminator, corruptWrittenHeader, corruptAppendedPayload
    }
    @TaskLocal static var testingFault: Fault?
    private(set) var verificationSeconds: LHASelfCheck.Timings = (v2: 0.0, v3: 0.0, total: 0.0)

    private let snapshot: ArchiveSourceSnapshot
    private let output: URL
    private let options: WriterOptions
    private let reader: ArchiveReader
    private let layout: LHALayout
    private let ledger: EntryEditLedger
    private let destination: SegmentedArchiveOutput
    private let encoder: (@Sendable (Data) throws -> Data)?
    private var renamedHeaders: [Int: Data] = [:]
    private var writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?
    private var appendStart: UInt64?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private var additionsClosed = false

    /// open 時の KaitoKit の名前。予約や追加は反映しない。
    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(snapshot: ArchiveSourceSnapshot, output: URL, options: WriterOptions, reader: ArchiveReader,
                 layout: LHALayout, names: [String], encoder: (@Sendable (Data) throws -> Data)?) {
        self.snapshot = snapshot; self.output = output; self.options = options
        self.reader = reader; self.layout = layout; self.encoder = encoder
        ledger = EntryEditLedger(names: names, entries: reader.entries)
        destination = SegmentedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "lzh",
                                           sequential: Self.testingDisablesClone)
    }
    deinit { if state != .committed { cleanup() } }

    /// output は存在しない file URL。親 directory は呼出側で用意する。
    /// .beginning と編集できない構造は open でだけ requiresRewrite を返す。
    public static func open(url: URL, output: URL, options: WriterOptions = WriterOptions()) throws -> LHAUpdater {
        try open(url: url, output: output, options: options, encoder: nil)
    }

    static func open(url: URL, output: URL, options: WriterOptions,
                     encoder: (@Sendable (Data) throws -> Data)?) throws -> LHAUpdater {
        try options.validate(for: .lha)
        guard options.additionPlacement == .end else { throw UpdaterRouteError.requiresRewrite(reason: "additionPlacement") }
        guard ArchiveVolumeSet.parse(fileName: url.lastPathComponent) == nil else {
            throw UpdaterRouteError.requiresRewrite(reason: "split volume name")
        }
        try ArchiveSourceSnapshot.validateOutput(output)
        try Task.checkCancellation()
        let snapshot = try ArchiveSourceSnapshot(url: url, directory: output.deletingLastPathComponent(),
                                                 pathExtension: "lzh", disablesClone: testingDisablesClone)
        let reader = try ArchiveReader.open(source: snapshot.source, sourceURL: url, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        guard reader.format == .lha else { throw UpdaterError.invalidArchive("LHA ではありません") }
        let representable = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: .lha, reader: reader)
        let layout = try LHALayout.scan(source: snapshot.source, reader: reader)
        try snapshot.checkUnchanged()
        return LHAUpdater(snapshot: snapshot, output: output, options: options, reader: reader, layout: layout,
                          names: representable.names, encoder: encoder)
    }

    /// 構造から分かる書き直し理由。nil でも open の独立した walk が拒否する場合がある。
    /// reader を変えず、終端の後ろを最大 64 KiB 読む。設定・分割巻名・独立した walk は判定しない。
    public static func rewriteReason(reader: ArchiveReader) -> String? { LHALayout.rewriteReason(reader: reader) }

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
            for index in indices { renamedHeaders.removeValue(forKey: index) }
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            let name = try ledger.rename(index, to: path, format: .lha, appendedBy: writer)
            let entry = reader.entries[index], directory = entry.kind == .directory
            if name == ledger.names[index] { renamedHeaders.removeValue(forKey: index) }
            else {
                let member = try layout.member(index)
                renamedHeaders[index] = try LHARecords.Entry(name: name, mode: ArchiveRepresentability.mode(for: entry),
                    size: entry.uncompressedSize ?? 0, date: entry.modificationDate ?? Date())
                    .header(method: directory ? LHARecords.Method.lhd : member.method,
                            packedSize: directory ? 0 : UInt32(member.dataRange.byteLength),
                            crc: directory ? 0 : member.crc16)
            }
            writerPathsNeedRefresh = true
        }
    }
    public func commit() throws { try commit(progress: nil) }

    /// total は書く byte、V2/V5 の照合読取、追加 block の長さの和。計画後は固定する。
    /// callback の throw・取消し・再入は失敗となる。成功後の再呼出しは何もしない。
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        if state == .committed { return }
        try perform {
            state = .committing
            try snapshot.checkUnchanged()
            let appendedEnd = try writer?.endAppendedMembers()
            let records = writer?.appendedLHAMemberRecords ?? []
            writer = nil
            let appended = appendedEnd.map { appendStart!..<$0 }
            let additionLength = appended?.byteLength ?? 0
            let plan = try makePlan(additionLength: additionLength)
            let prefix = plan.isChanged ? plan.prefix : [.source(0..<snapshot.source.length)]
            let finalLength = plan.isChanged ? try checkedAdd(plan.membersEnd, checkedAdd(additionLength, 1)) : snapshot.source.length
            let outputPlan = SegmentCommitPlan(prefix: prefix, appended: appended, terminal: plan.terminal,
                finalLength: finalLength, formatVerificationUnits: try checkedAdd(plan.boundaryBytes * 2, additionLength))
            let meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: { update in
                try progress?(update)
                guard self.state == .committing else { throw UpdaterError.invalidState }
            })
            try Task.checkCancellation()
            try meter.start()
            let fault = Self.testingFault.map {
                LHASelfCheck.faultAction($0, plan: plan, finalLength: finalLength, records: records, appendStart: appendStart)
            }
            let strategy = try SegmentedArchiveOutput.$testingBeforeSynchronize.withValue(fault) {
                try destination.commit(outputPlan, meter: meter) { fd, advance in
                    self.verificationSeconds = try LHASelfCheck.verify(plan: plan, records: records, additionLength: additionLength,
                        finalLength: finalLength, descriptor: fd, source: self.snapshot.source, layout: self.layout,
                        appendStart: self.appendStart, advance: advance)
                }
            }
            try meter.finish()
            try Task.checkCancellation()
            snapshot.cleanup()
            lastCommitStrategy = CommitStrategy(strategy, appendWasSplice: !ledger.removed.isEmpty || !plan.changed.isEmpty)
            state = .committed
        }
    }

    private func makePlan(additionLength: UInt64 = 0) throws -> LHAEditPlan {
        try LHAEditPlan.make(layout: layout, removed: ledger.removed, renamed: renamedHeaders, additionLength: additionLength)
    }
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh { writer.replaceExistingPaths(ledger.existingPaths); writerPathsNeedRefresh = false }
            return writer
        }
        let plan = try makePlan()
        let handle = try destination.beginAppend(at: plan.membersEnd, prefix: plan.prefix)
        let writer = try ArchiveWriter.lhaAppend(output: handle, url: output, at: plan.membersEnd,
                                                 options: options, existingPaths: ledger.existingPaths, encoder: encoder)
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
    // writer の衝突・符号化失敗も transaction 全体の失敗。abort は clone も含め出力を無効にする。
    private func cleanup() { writer = nil; destination.discard() }
}

extension LHAUpdater.CommitStrategy {
    /// 共有出力の結果を LHA の語に写す。appendOnly でも削除・改名があれば splice と数える。
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
