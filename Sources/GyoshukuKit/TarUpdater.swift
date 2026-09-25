import Foundation
private import Darwin
internal import KaitoKit

/// open 時の書き直し要求と、commit 時の出力照合失敗を区別する。
public enum TarUpdaterError: Error, Sendable, Equatable {
    case requiresRewrite(reason: String)
    case outputVerificationFailed(reason: String)
}

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
    private let names: [String]
    private let rawNames: [Data]
    private let hardLinkTargets: [Int: Int]
    private let dataTargets: [Int: Int]
    private let destination: SplicedArchiveOutput
    private var removed: Set<Int> = []
    private var renamed: [Int: String] = [:]
    private lazy var reservations = EditPathReservations(existingPaths)
    private var indexedAppendCount = 0
    private var writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?
    private var appendStart: UInt64?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding

    /// 常に open 時の名前。予約や追加は反映しない。
    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(snapshot: ArchiveSourceSnapshot, output: URL, options: WriterOptions, reader: ArchiveReader,
                 layout: TarLayout, names: [String], hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        self.snapshot = snapshot
        self.output = output
        self.options = options
        self.reader = reader
        self.layout = layout
        self.names = names
        rawNames = reader.entries.map { Data($0.rawName.bytes) }
        self.hardLinkTargets = hardLinkTargets
        self.dataTargets = dataTargets
        destination = SplicedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "tar",
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
        let representable = try ArchiveRewriter.validateRepresentability(entries: reader.entries, format: .tar, reader: reader)
        let layout = try TarLayout.scan(source: snapshot.source, length: snapshot.source.length, entries: reader.entries,
                                        nameEncoding: reader.nameEncoding, hardLinkTargets: representable.hardLinkTargets,
                                        dataTargets: representable.dataTargets)
        try snapshot.checkUnchanged()
        return TarUpdater(snapshot: snapshot, output: output, options: options, reader: reader, layout: layout,
                          names: representable.names, hardLinkTargets: representable.hardLinkTargets, dataTargets: representable.dataTargets)
    }

    public func add(contentsOf url: URL, as path: String) throws { try add(contentsOf: url, as: path, ownerIDs: nil) }
    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        try perform { try preparedWriter().add(contentsOf: url, as: path, ownerIDs: ownerIDs) }
    }
    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try perform { try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions) }
    }
    public func addDirectory(_ path: String) throws { try addDirectory(path, modificationDate: nil, ownerIDs: nil) }
    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        try perform { try preparedWriter().addDirectory(path, modificationDate: modificationDate, ownerIDs: ownerIDs) }
    }
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            for index in indices { try validateIndex(index) }
            indexAppendedPaths()
            for index in indices where !removed.contains(index) {
                let name = renamed[index] ?? names[index]
                if !name.isEmpty { reservations.remove(name, directory: reader.entries[index].kind == .directory) }
                removed.insert(index)
                renamed.removeValue(forKey: index)
            }
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
            let directory = reader.entries[index].kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .tar)
            indexAppendedPaths()
            let old = renamed[index] ?? names[index]
            if !old.isEmpty { reservations.remove(old, directory: directory) }
            try reservations.validate(name, directory: directory)
            reservations.insert(name, directory: directory)
            renamed[index] = name
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
            let appendedEnd = try writer?.endTarMembers()
            writer = nil
            let appended = appendedEnd.map { appendStart!..<$0 }
            let plan = try makePlan(additionLength: appended.map { $0.upperBound - $0.lowerBound } ?? 0)
            let prefix: [SplicedSegment] = plan.isChanged ? plan.prefix : [.source(0..<snapshot.source.length)]
            let finalLength = plan.isChanged ? try checkedAdd(plan.membersEnd,
                checkedAdd(appended.map { $0.upperBound - $0.lowerBound } ?? 0, UInt64(plan.terminal.count))) : snapshot.source.length
            let outputPlan = SplicedCommitPlan(prefix: prefix, appended: appended, terminal: plan.terminal,
                finalLength: finalLength, formatVerificationUnits: UInt64(plan.boundaries.count) * 1024)
            let meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: { update in
                try progress?(update)
                guard self.state == .committing else { throw UpdaterError.invalidState }
            })
            try Task.checkCancellation()
            try meter.start()
            let fault = Self.faultAction(plan: plan, finalLength: finalLength)
            let strategy = try SplicedArchiveOutput.$testingBeforeSynchronize.withValue(fault) {
                try destination.commit(outputPlan, meter: meter) { fd, advance in
                    try self.verify(plan: plan, appendedPaths: appendedPaths,
                                    additionLength: appended.map { $0.upperBound - $0.lowerBound } ?? 0,
                                    finalLength: finalLength, descriptor: fd, advance: advance)
                }
            }
            try meter.finish()
            try Task.checkCancellation()
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

    private func makePlan(additionLength: UInt64 = 0) throws -> TarEditPlan {
        do { return try TarEditPlan.make(layout: layout, source: snapshot.source, names: names, rawNames: rawNames,
                             hardLinkTargets: hardLinkTargets, dataTargets: dataTargets, removed: removed,
                             renamed: renamed, additionLength: additionLength) }
        catch TarUpdaterError.requiresRewrite { throw UpdaterError.sourceChanged }
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
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw WriterError.io(operation: "fstat append", code: errno) }
        let identity = (info.st_dev, info.st_ino)
        let tar = TarWriter(output: handle, url: output, identity: identity, compressor: nil, startPosition: plan.membersEnd)
        tar.observesWrites = true
        let writer = ArchiveWriter(output: handle, url: output, identity: identity, format: .tar, options: options, tarWriter: tar)
        try writer.prepareAppend(at: plan.membersEnd, existingPaths: existingPaths)
        self.writer = writer
        appendStart = plan.membersEnd
        writerPathsNeedRefresh = false
        return writer
    }

    private func verify(plan: TarEditPlan, appendedPaths: [(String, Bool)], additionLength: UInt64,
                        finalLength: UInt64, descriptor: Int32, advance: (UInt64) throws -> Void) throws {
        var progressError: Error?
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, UInt64(info.st_size) == finalLength else {
                throw TarUpdaterError.outputVerificationFailed(reason: "V4 length")
            }
            guard plan.isChanged else { return }
            for change in plan.changed {
                let expected = try TarHeaderRewrite.rewrite(source: snapshot.source, unit: layout.member(change.index),
                    name: change.name, link: change.link, materializedSize: change.materializedTarget.map { layout.member($0).storedSize })
                let actual = try SplicedArchiveOutput.read(descriptor, at: change.outputOffset, count: Int(change.headerLength))
                guard actual == expected else { throw TarUpdaterError.outputVerificationFailed(reason: "V1 header group") }
                try TarLayout.validateChecksum(Data(actual.suffix(512)))
            }
            for boundary in plan.boundaries {
                try Task.checkCancellation()
                let source = try SplicedArchiveOutput.read(snapshot.source.descriptor, at: boundary.source, count: 512, counted: true)
                let output = try SplicedArchiveOutput.read(descriptor, at: boundary.output, count: 512, counted: true)
                do { try advance(1024) } catch { progressError = error; throw error }
                guard source == output else { throw TarUpdaterError.outputVerificationFailed(reason: "V2 boundary header") }
            }
            if additionLength > 0 {
                let view = TarOutputView(descriptor: descriptor, length: finalLength)
                var count = 0
                let walk = try TarLayout.walk(source: view, range: plan.membersEnd..<(plan.membersEnd + additionLength)) { index, _, group in
                    guard index < appendedPaths.count, group.name == Data(appendedPaths[index].0.utf8) else {
                        throw TarUpdaterError.outputVerificationFailed(reason: "V3 added name")
                    }
                    count += 1
                }
                guard count == appendedPaths.count, walk.membersEnd == plan.membersEnd + additionLength else {
                    throw TarUpdaterError.outputVerificationFailed(reason: "V3 added bounds")
                }
            }
            let terminal = try SplicedArchiveOutput.read(descriptor, at: plan.membersEnd + additionLength, count: plan.terminal.count)
            guard terminal == plan.terminal, terminal.count >= 1024 else { throw TarUpdaterError.outputVerificationFailed(reason: "V4 EOF") }
        } catch {
            if let progressError { throw progressError }
            if error is CancellationError { throw error }
            if let failure = error as? TarUpdaterError, case .outputVerificationFailed = failure { throw failure }
            throw TarUpdaterError.outputVerificationFailed(reason: "tar verification: \(error)")
        }
    }

    private static func faultAction(plan: TarEditPlan, finalLength: UInt64) -> (@Sendable (Int32) throws -> Void)? {
        guard let fault = testingFault else { return nil }
        let changedOffset = plan.changed.first?.outputOffset ?? plan.membersEnd
        let moved = plan.boundaries.first(where: { $0.source != $0.output })?.output ?? 0
        return { fd in
            let offset: UInt64
            switch fault {
            case .flipWrittenByte(let value): offset = value
            case .shiftSourceSegment:
                let bytes = try SplicedArchiveOutput.read(fd, at: moved + 512, count: 512)
                try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: moved) }
                return
            case .corruptWrittenHeader: offset = changedOffset
            case .dropTerminatorBlock:
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).truncate(atOffset: finalLength - 512)
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
    private func cleanup() { writer = nil; destination.discard() }
}

private struct TarOutputView: ByteSource {
    let descriptor: Int32
    let length: UInt64
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let bytes = try SplicedArchiveOutput.read(descriptor, at: offset, count: Int(min(UInt64(buffer.count), length - offset)))
        bytes.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        return bytes.count
    }
}
