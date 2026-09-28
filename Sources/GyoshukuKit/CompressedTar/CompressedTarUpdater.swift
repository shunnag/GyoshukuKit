import Foundation
private import Darwin
@_spi(TarEditLayout) public import KaitoKit

/// session reader の復号済み tar と地図を使い、変更を含む区切りだけを符号化する。
/// 原本のパスは開かない。追加は末尾、運ぶ member は所有者と名前の byte を保つ。
/// 従来の設定（.beginning / .reset）は open で requiresRewrite を返す。
/// 公開前に KaitoKit.openSplicedCompressedTar で検証すること。
/// 全体の open による検証へ戻してよいのは K5 が baseNotSpliceable を返した場合だけ。
/// thread-safe ではない。失敗後は再利用できず、deinit は未完了の出力を削除する。
public final class CompressedTarUpdater: ArchiveEditing {
    // Swift 6.3 の @TaskLocal は展開した `$` の宣言に @_spi を付けないため、SPI の型を使う試験用の値は
    // 他の updater と同じく internal にする（試験は @testable import で使う）。
    enum Fault: Sendable {
        case trailerCRC, missingDictionaryProtection, dropBzip2Stream, xzIndexLength, dropXZBlock,
             flipEncodedByte, shiftLedger, flipReusedByte
    }
    @TaskLocal static var testingFault: Fault?
    @TaskLocal static var testingSkipsSelfCheck = false
    @TaskLocal static var testingForcesFullEncode = false
    @_spi(Testing) public private(set) var lastCommitStatistics: CompressedTarCommitStatistics?
    enum Stage: Sendable { case planned, encoding, copying, selfCheck }
    @TaskLocal static var testingStage: (@Sendable (Stage) throws -> Void)?

    public let entryNames: [String]
    private var editingSnapshot: TarEditingSnapshot?
    private let entries: [ArchiveEntry]
    private let output: URL
    private let format: ArchiveFormat
    private let options: WriterOptions
    private let layout: TarLayout
    private let names: [String], rawNames: [Data]
    private let hardLinkTargets: [Int: Int], dataTargets: [Int: Int]
    private var removed = Set<Int>(), renamed: [Int: String] = [:]
    private lazy var reservations = EditPathReservations(existingPaths)
    private var indexedAppendCount = 0, writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?, tarWriter: TarWriter?, storage: TarSpliceStorage?
    private var destination: CompressedTarSpliceOutput?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private var additionsClosed = false
    private var result: CompressedTarCommitResult?

    private init(editingSnapshot: TarEditingSnapshot, entries: [ArchiveEntry], output: URL, format: ArchiveFormat,
                 options: WriterOptions, layout: TarLayout, names: [String],
                 hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        self.editingSnapshot = editingSnapshot; self.entries = entries; entryNames = entries.map(\.name)
        self.output = output; self.format = format; self.options = options; self.layout = layout
        self.names = names; rawNames = entries.map { Data($0.rawName.bytes) }
        self.hardLinkTargets = hardLinkTargets; self.dataTargets = dataTargets
    }
    deinit { if state != .committed { cleanup() } }

    public static func assess(reader: ArchiveReader) -> CompressedTarAssessment? {
        guard reader.nameEncoding == nil, let snapshot = reader.tarEditingSnapshot(),
              let layout = snapshot.layout, snapshot.archiveIdentity != nil,
              let format = format(snapshot.container) else { return nil }
        let reason = CompressedTarSplicePlan.framingReason(snapshot)
        return CompressedTarAssessment(format: format, framingReusable: reason == nil,
            hasInteriorBoundaries: snapshot.chunkMap?.hasInteriorBoundaries ?? false,
            imageLength: layout.imageLength, reason: reason)
    }

    /// reader は recordsTarEditLayout を立てて開く。open は出力も一時ファイルも作らない。
    public static func open(reader: sending ArchiveReader, output: URL, format: ArchiveFormat,
                            options: WriterOptions = WriterOptions()) throws -> CompressedTarUpdater {
        try options.validate(for: format)
        guard [.tarGzip, .tarBzip2, .tarXZ].contains(format) else { throw WriterError.unsupportedOption("format") }
        guard options.additionPlacement == .end else { throw TarLayout.refuse("additionPlacement") }
        guard options.carriedTarOwnerIDs == .keep else { throw TarLayout.refuse("carriedTarOwnerIDs") }
        try ArchiveSourceSnapshot.validateOutput(output)
        try Task.checkCancellation()
        guard let snapshot = reader.tarEditingSnapshot() else { throw TarLayout.refuse("missing tar editing snapshot") }
        guard reader.nameEncoding == nil else { throw TarLayout.refuse("R10: name encoding") }
        guard Self.format(snapshot.container) == format else { throw TarLayout.refuse("container mismatch") }
        guard let k1 = snapshot.layout else { throw TarLayout.refuse("layout: \(String(describing: snapshot.layoutUnavailableReason))") }
        guard snapshot.archiveIdentity != nil else { throw TarLayout.refuse("missing archive identity") }
        guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
        let represented = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: format, reader: reader)
        let layout = try TarLayout.scan(source: snapshot.image, length: k1.imageLength, entries: reader.entries,
            nameEncoding: reader.nameEncoding, hardLinkTargets: represented.hardLinkTargets, dataTargets: represented.dataTargets)
        guard layout.memberUnitIndices.count == k1.memberCount, layout.membersEnd == k1.endOfArchiveOffset,
              layout.units.filter(\.isGlobal).map(\.range) == k1.globalHeaderRanges else { throw TarLayout.refuse("R8: layout mismatch") }
        for index in 0..<k1.memberCount {
            if index & 1023 == 0 { try Task.checkCancellation() }
            let unit = layout.member(index), member = try k1.member(at: index)
            guard unit.range == member.groupRange, unit.headerStart == member.headerOffset,
                  unit.dataStart == member.headerRange.upperBound else { throw TarLayout.refuse("R8: layout mismatch") }
        }
        guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
        return CompressedTarUpdater(editingSnapshot: snapshot, entries: reader.entries, output: output, format: format,
            options: options, layout: layout, names: represented.names,
            hardLinkTargets: represented.hardLinkTargets, dataTargets: represented.dataTargets)
    }

    private static func format(_ container: TarContainer) -> ArchiveFormat? {
        switch container { case .gzip: .tarGzip; case .bzip2: .tarBzip2; case .xz: .tarXZ; default: nil }
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
            for index in indices { try validateIndex(index) }
            indexAppendedPaths()
            for index in indices where !removed.contains(index) {
                let name = renamed[index] ?? names[index]
                if !name.isEmpty { reservations.remove(name, directory: entries[index].kind == .directory) }
                removed.insert(index); renamed.removeValue(forKey: index)
            }
            writerPathsNeedRefresh = true
        }
    }
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
            let directory = entries[index].kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .tar)
            indexAppendedPaths()
            let old = renamed[index] ?? names[index]
            if !old.isEmpty { reservations.remove(old, directory: directory) }
            try reservations.validate(name, directory: directory)
            reservations.insert(name, directory: directory)
            renamed[index] = name; writerPathsNeedRefresh = true
        }
    }
    public func commit() throws { _ = try commit(progress: nil) }

    @discardableResult
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws -> CompressedTarCommitResult {
        if let result { return result }
        try perform {
            state = .committing
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = self.editingSnapshot!
            guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
            let additionLength = try writer?.endTarMembers() ?? 0
            let additions = tarWriter?.memberLayouts ?? []
            writer = nil; tarWriter = nil
            let plan = try TarEditPlan.make(layout: layout, source: snapshot.image, names: names, rawNames: rawNames,
                hardLinkTargets: hardLinkTargets, dataTargets: dataTargets, removed: removed,
                renamed: renamed, additionLength: additionLength)
            let image: TarImageSource?
            let splice: CompressedTarSplicePlan?
            if plan.isChanged {
                image = try TarImageSource.make(plan: plan, layout: layout, original: snapshot.image,
                    storage: preparedStorage(), additionLength: additionLength, additions: additions)
                splice = try CompressedTarSplicePlan.make(snapshot: snapshot, image: image!, format: format, options: options,
                    force: Self.testingForcesFullEncode, ignoresWindow: Self.testingFault == .missingDictionaryProtection)
            } else { image = nil; splice = nil }
            let planning = ProcessInfo.processInfo.systemUptime - started
            try Self.testingStage?(.planned)
            try Task.checkCancellation()
            let destination = CompressedTarSpliceOutput(output: output, snapshot: snapshot, format: format, options: options)
            self.destination = destination
            let committed = try destination.commit(image: image, plan: splice, progress: { update in
                try progress?(update)
                guard self.state == .committing else { throw UpdaterError.invalidState }
            })
            try Task.checkCancellation()
            lastCommitStatistics = destination.statistics(planning: planning, scratch: storage?.written ?? 0, result: committed)
            result = committed
            destination.keep()
            self.destination = nil; storage = nil; self.editingSnapshot = nil
            state = .committed
        }
        return result!
    }

    private var existingPaths: [(String, Bool)] {
        entries.compactMap { entry in
            let name = renamed[entry.index] ?? names[entry.index]
            return removed.contains(entry.index) || name.isEmpty ? nil : (name, entry.kind == .directory)
        }
    }
    private func indexAppendedPaths() {
        for (name, directory) in (writer?.appendedPaths ?? []).dropFirst(indexedAppendCount) { reservations.insert(name, directory: directory) }
        indexedAppendCount = writer?.appendedPaths.count ?? indexedAppendCount
    }
    private func validateIndex(_ index: Int) throws {
        guard entries.indices.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
    }
    private func preparedStorage() throws -> TarSpliceStorage {
        if let storage { return storage }
        let storage = try TarSpliceStorage(directory: output.deletingLastPathComponent())
        self.storage = storage
        return storage
    }
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            if writerPathsNeedRefresh { writer.replaceExistingPaths(existingPaths); writerPathsNeedRefresh = false }
            return writer
        }
        let storage = try preparedStorage()
        let fd = fcntl(storage.handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw WriterError.io(operation: "dup append storage", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let tar = TarWriter(output: handle, url: storage.url, compressor: nil)
        tar.recordsMemberLayout = true; tar.observesWrites = true
        tar.willWrite = { [storage] in try storage.willWrite($0) }
        let writer = ArchiveWriter(output: handle, url: storage.url, format: .tar,
                                   options: options, tarWriter: tar)
        try writer.prepareAppend(at: 0, existingPaths: existingPaths)
        self.writer = writer; tarWriter = tar; writerPathsNeedRefresh = false
        return writer
    }
    private func perform(_ body: () throws -> Void) throws {
        guard state == .adding else {
            if state == .committing { state = .failed }
            throw UpdaterError.invalidState
        }
        do { try Task.checkCancellation(); try body() }
        catch {
            state = .failed; cleanup()
            if case TarUpdaterError.requiresRewrite = error { throw UpdaterError.sourceChanged }
            throw error
        }
    }
    private func cleanup() {
        writer = nil; tarWriter = nil; storage = nil
        destination?.discard(); destination = nil; editingSnapshot = nil
    }
}
