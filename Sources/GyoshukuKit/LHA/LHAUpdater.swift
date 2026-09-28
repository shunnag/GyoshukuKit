import Foundation
private import Darwin
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
    private(set) var verificationSeconds = (v2: 0.0, v3: 0.0, total: 0.0)

    private let snapshot: ArchiveSourceSnapshot
    private let output: URL
    private let options: WriterOptions
    private let reader: ArchiveReader
    private let layout: LHALayout
    private let names: [String]
    private let destination: SplicedArchiveOutput
    private let encoder: @Sendable (Data) throws -> Data
    private var removed: Set<Int> = []
    private var renamed: [Int: String] = [:]
    private var renamedHeaders: [Int: Data] = [:]
    private lazy var reservations = EditPathReservations(existingPaths)
    private var indexedAppendCount = 0
    private var writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?
    private var lhaWriter: LHAWriter?
    private var appendStart: UInt64?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private var additionsClosed = false

    /// open 時の KaitoKit の名前。予約や追加は反映しない。
    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(snapshot: ArchiveSourceSnapshot, output: URL, options: WriterOptions, reader: ArchiveReader,
                 layout: LHALayout, names: [String], encoder: @escaping @Sendable (Data) throws -> Data) {
        self.snapshot = snapshot; self.output = output; self.options = options
        self.reader = reader; self.layout = layout; self.names = names; self.encoder = encoder
        destination = SplicedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "lzh",
                                           sequential: Self.testingDisablesClone)
    }
    deinit { if state != .committed { cleanup() } }

    /// output は存在しない file URL。親 directory は呼出側で用意する。
    /// .beginning と編集できない構造は open でだけ requiresRewrite を返す。
    public static func open(url: URL, output: URL, options: WriterOptions = WriterOptions()) throws -> LHAUpdater {
        try open(url: url, output: output, options: options, encoder: LH5Encoder.encode)
    }

    static func open(url: URL, output: URL, options: WriterOptions,
                     encoder: @escaping @Sendable (Data) throws -> Data) throws -> LHAUpdater {
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
        let representable = try ArchiveRewriter.validateRepresentability(entries: reader.entries, format: .lha, reader: reader)
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
            for index in indices { try validateIndex(index) }
            indexAppendedPaths()
            for index in indices where !removed.contains(index) {
                let name = renamed[index] ?? names[index]
                if !name.isEmpty { reservations.remove(name, directory: reader.entries[index].kind == .directory) }
                removed.insert(index); renamed.removeValue(forKey: index); renamedHeaders.removeValue(forKey: index)
            }
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
            let entry = reader.entries[index], directory = entry.kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .lha)
            indexAppendedPaths()
            let old = renamed[index] ?? names[index]
            if !old.isEmpty { reservations.remove(old, directory: directory) }
            try reservations.validate(name, directory: directory)
            reservations.insert(name, directory: directory)
            renamed[index] = name
            if name == names[index] { renamedHeaders.removeValue(forKey: index) }
            else {
                let member = try layout.member(index)
                renamedHeaders[index] = try LHARecords.Entry(name: name, mode: ArchiveRewriter.mode(for: entry),
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
            let appendedEnd = try writer?.endLHAMembers()
            let records = lhaWriter?.memberRecords ?? []
            writer = nil; lhaWriter = nil
            let appended = appendedEnd.map { appendStart!..<$0 }
            let additionLength = appended?.byteLength ?? 0
            let plan = try makePlan(additionLength: additionLength)
            let prefix = plan.isChanged ? plan.prefix : [.source(0..<snapshot.source.length)]
            let finalLength = plan.isChanged ? try checkedAdd(plan.membersEnd, checkedAdd(additionLength, 1)) : snapshot.source.length
            let outputPlan = SplicedCommitPlan(prefix: prefix, appended: appended, terminal: plan.terminal,
                finalLength: finalLength, formatVerificationUnits: try checkedAdd(plan.boundaryBytes * 2, additionLength))
            let meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: { update in
                try progress?(update)
                guard self.state == .committing else { throw UpdaterError.invalidState }
            })
            try Task.checkCancellation()
            try meter.start()
            let fault = Self.faultAction(plan: plan, finalLength: finalLength, records: records, appendStart: appendStart)
            let strategy = try SplicedArchiveOutput.$testingBeforeSynchronize.withValue(fault) {
                try destination.commit(outputPlan, meter: meter) { fd, advance in
                    try self.verify(plan: plan, records: records, additionLength: additionLength,
                                    finalLength: finalLength, descriptor: fd, advance: advance)
                }
            }
            try meter.finish()
            try Task.checkCancellation()
            snapshot.cleanup()
            switch strategy {
            case .unchanged: lastCommitStrategy = .unchanged
            case .inPlacePatch: lastCommitStrategy = .inPlacePatch
            case .appendOnly: lastCommitStrategy = removed.isEmpty && plan.changed.isEmpty ? .appendOnly : .splice
            case .splice: lastCommitStrategy = .splice
            case .sequential: lastCommitStrategy = .sequential
            case .relocatedAppend: lastCommitStrategy = .relocatedAppend
            }
            state = .committed
        }
    }

    private func makePlan(additionLength: UInt64 = 0) throws -> LHAEditPlan {
        try LHAEditPlan.make(layout: layout, removed: removed, renamed: renamedHeaders, additionLength: additionLength)
    }
    private var existingPaths: [(String, Bool)] {
        reader.entries.compactMap { entry in
            let name = renamed[entry.index] ?? names[entry.index]
            return removed.contains(entry.index) || name.isEmpty ? nil : (name, entry.kind == .directory)
        }
    }
    private func indexAppendedPaths() {
        for (name, directory) in (writer?.appendedPaths ?? []).dropFirst(indexedAppendCount) {
            reservations.insert(name, directory: directory)
        }
        indexedAppendCount = writer?.appendedPaths.count ?? indexedAppendCount
    }
    private func validateIndex(_ index: Int) throws {
        guard reader.entries.indices.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
    }
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh { writer.replaceExistingPaths(existingPaths); writerPathsNeedRefresh = false }
            return writer
        }
        let plan = try makePlan()
        let handle = try destination.beginAppend(at: plan.membersEnd, prefix: plan.prefix)
        let lha = LHAWriter(output: handle, url: output, threads: options.resolvedCompressionThreads, encoder: encoder)
        lha.recordsMembers = true
        let writer = ArchiveWriter(output: handle, url: output, format: .lha, options: options, lhaWriter: lha)
        try writer.prepareAppend(at: plan.membersEnd, existingPaths: existingPaths)
        self.writer = writer; lhaWriter = lha; appendStart = plan.membersEnd; writerPathsNeedRefresh = false
        return writer
    }

    private func verify(plan: LHAEditPlan, records: [LHAWriter.MemberRecord], additionLength: UInt64,
                        finalLength: UInt64, descriptor: Int32, advance: (UInt64) throws -> Void) throws {
        let started = ProcessInfo.processInfo.systemUptime
        defer { verificationSeconds.total = ProcessInfo.processInfo.systemUptime - started }
        var progressError: Error?
        func advancing(_ count: UInt64) throws {
            do { try advance(count) } catch { progressError = error; throw error }
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) == finalLength else { throw failure("V4 length") }
            guard plan.isChanged else { return }
            let source = try ArchiveFileSource(duplicating: descriptor)
            for change in plan.changed {
                try Task.checkCancellation()
                let actual = try SplicedArchiveOutput.read(descriptor, at: change.outputOffset, count: change.header.count)
                guard actual == change.header, actual.first != 0 else { throw failure("V1 header") }
                let original = try layout.member(change.index)
                let payloadLength = original.dataRange.byteLength
                let end = change.outputOffset + UInt64(change.header.count) + payloadLength
                let walked = try LHALayout.walk(source: source, range: change.outputOffset..<end) { index, header in
                    guard index == 0, header.member.headerLevel == 2, header.member.method == original.method,
                          header.member.crc16 == (original.method == LHARecords.Method.lhd ? 0 : original.crc16),
                          header.member.dataRange.byteLength == payloadLength else {
                        throw self.failure("V1 parsed header")
                    }
                }
                guard walked.count == 1, walked.end == end, !walked.terminated else { throw failure("V1 bounds") }
            }
            let v2Start = ProcessInfo.processInfo.systemUptime
            for boundary in plan.boundaries {
                try Task.checkCancellation()
                let original = try SplicedArchiveOutput.read(snapshot.source.descriptor, at: boundary.source, count: Int(boundary.length), counted: true)
                let written = try SplicedArchiveOutput.read(descriptor, at: boundary.output, count: Int(boundary.length), counted: true)
                try advancing(boundary.length * 2)
                guard original == written else { throw failure("V2 boundary header") }
            }
            verificationSeconds.v2 = ProcessInfo.processInfo.systemUptime - v2Start
            if additionLength > 0 {
                let v3Start = ProcessInfo.processInfo.systemUptime
                do {
                    try LHAAppendedMemberCheck.verify(descriptor: descriptor, at: plan.membersEnd, originalStart: appendStart!,
                                                      length: additionLength, records: records, advance: advancing)
                } catch {
                    if error is CancellationError { throw error }
                    throw failure("V3: \(error)")
                }
                verificationSeconds.v3 = ProcessInfo.processInfo.systemUptime - v3Start
            }
            guard try SplicedArchiveOutput.read(descriptor, at: finalLength - 1, count: 1) == Data([0]) else { throw failure("V4 terminator") }
        } catch {
            if let progressError { throw progressError }
            if error is CancellationError { throw error }
            if let failure = error as? UpdaterRouteError, case .outputVerificationFailed = failure { throw failure }
            throw failure("LHA verification: \(error)")
        }
    }
    private func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: reason) }

    private static func faultAction(plan: LHAEditPlan, finalLength: UInt64, records: [LHAWriter.MemberRecord],
                                    appendStart: UInt64?) -> (@Sendable (Int32) throws -> Void)? {
        guard let fault = testingFault else { return nil }
        let header = plan.changed.first?.outputOffset ?? plan.membersEnd
        let boundary = plan.boundaries.first?.output ?? 0
        let membersEnd = plan.membersEnd
        let payload = records.first.map { plan.membersEnd + $0.headerOffset - (appendStart ?? 0) + $0.headerLength }
        return { fd in
            let offset: UInt64
            switch fault {
            case .flipWrittenByte(let value): offset = value
            case .shiftSourceSegment:
                let bytes = try SplicedArchiveOutput.read(fd, at: boundary + 1, count: 21)
                try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: boundary) }
                return
            case .corruptWrittenHeader: offset = header
            case .corruptAppendedPayload: offset = payload ?? membersEnd
            case .dropTerminator:
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).truncate(atOffset: finalLength - 1)
                return
            }
            var byte = try SplicedArchiveOutput.read(fd, at: offset, count: 1)
            byte[0] ^= 1
            try byte.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: offset) }
        }
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
    private func cleanup() { writer = nil; lhaWriter = nil; destination.discard() }
}
