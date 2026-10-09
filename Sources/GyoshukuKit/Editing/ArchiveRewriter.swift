import Foundation
private import Darwin
public import KaitoKit

public enum RewriterError: Error, Sendable, Equatable {
    /// 出力を作る前に、最初の表現できない entry を報告する。
    case unrepresentable(entry: String, reason: String)
    /// header の復号失敗は nil、entry の復号失敗は open 時の名前。
    case password(entry: String?)
    case invalidArchive(String)
    case invalidState
}

/// KaitoKit が読める書庫を全 entry の再圧縮で編集・変換する。options.password で出力を暗号化する。
/// thread-safe ではない。呼出側は同じ書庫への操作も直列化する。
/// 既定では生き残る entry の後ろへ追加する。ディスク追加元は commit まで同一に保つこと。
/// .beginning は add 時に出力し、commit 時に既存 entry を後ろへ運ぶ。
/// open 時の一つの reader を使い続け、solid group の decoder state を維持する。
/// 先頭の . を除いた名前が空の root directory は、実名へ改名されない限り出力しない。
/// root も entryNames に残り、その index の削除・改名は他の entry と同じように扱う。
/// hard link の参照先は link より前の index に限る。tar は参照先の改名後の名前を使い、
/// 参照先が削除された場合と tar 以外への出力では、参照先の内容を通常ファイルとして運ぶ。
/// その内容は参照先の順番で一時ファイルへ保存し、reader を巻き戻さない。
/// 失敗後は再利用できない。deinit は未 commit の作業ディレクトリ・部分出力を削除する。
public final class ArchiveRewriter: ArchiveEditing {
    private let url: URL
    private let output: URL?
    private let format: ArchiveFormat
    private let options: WriterOptions
    private let source: ArchiveFileSource
    private let reader: ArchiveReader
    private let ledger: EntryEditLedger
    private let hardLinkTargets: [Int: Int]
    private let dataTargets: [Int: Int]
    private var writerPathsNeedRefresh = false
    private var writer: ArchiveWriter?
    private enum Addition {
        case disk(URL, String, ArchiveOwnerIDs?, DiskSignature)
        case data(Data, String, Date?, UInt16?)
        case directory(String, Date?, ArchiveOwnerIDs?)
    }
    private var additions: [Addition] = []
    private var workDirectory: URL?
    private var destination: URL?
    private var destinationHandle: FileHandle?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private var additionsClosed = false

    public let sourceFormat: KaitoKit.ArchiveFormat
    public let hasEncryptedEntries: Bool

    /// 予約済みの削除・改名や追加を反映せず、常に open 時の名前を返す。
    public var entryNames: [String] { reader.entries.map(\.name) }

    public var readsAdditionsDuringCommit: Bool { options.additionPlacement == .end }
    var pendingInputBytes: UInt64 { writer?.pendingInputBytes ?? 0 }

    /// 自身の追加の入口だけを閉じる。carry との間で圧縮 block を区切らない。
    public func finishAdditions(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try perform {
            additionsClosed = true
            let meter = CommitProgressMeter(total: 0, progress: progress)
            try meter.start()
            try Task.checkCancellation()
            try meter.finish()
        }
    }

    /// open 時に内部の reader が組み立てた分割巻と同一性を返す。単一ファイルは nil。
    /// checkUnchanged は open に渡した URL 自身のファイルだけを検査する。
    /// 分割セットを編集する呼出側は、編集を再生する前に自身が記録したセットの同一性と必ず照合する。
    public var volumeSet: ArchiveVolumeSet? { reader.volumeSet }

    private init(url: URL, output: URL?, format: ArchiveFormat, options: WriterOptions,
                 source: ArchiveFileSource, reader: ArchiveReader, names: [String],
                 hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        self.url = url
        self.output = output
        self.format = format
        self.options = options
        self.source = source
        self.reader = reader
        ledger = EntryEditLedger(names: names, entries: reader.entries)
        self.hardLinkTargets = hardLinkTargets
        self.dataTargets = dataTargets
        sourceFormat = reader.format
        hasEncryptedEntries = reader.entries.contains { $0.isEncrypted }
    }

    deinit { cleanup() }

    /// output が nil なら同じ volume 上の一時出力で原本を置換し、指定時は新規作成する。
    /// 全 entry の表現可能性を検証するまで、出力や作業ディレクトリを作らない。
    /// password は入力の復号用、options.password は出力の暗号化用として独立に指定する。
    public static func open(url: URL, password: String? = nil, output: URL? = nil,
                            format: ArchiveFormat, options: WriterOptions = WriterOptions()) throws -> ArchiveRewriter {
        let options = options.resolvingCompressionThreads()
        try options.validate(for: format)
        let source: ArchiveFileSource
        let reader: ArchiveReader
        do {
            source = try ArchiveFileSource(url: url)
            // sidecar を保持し、index の詰め直しと resource fork の擬似 entry を編集に持ち込まない。
            reader = try ArchiveReader.open(url: url, options: ReaderOptions(
                limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max),
                password: password,
                appleDoublePolicy: .expose))
            try source.checkUnchanged(at: url)
        } catch let error as KaitoError {
            throw ArchiveRepresentability.map(error, entry: nil)
        } catch let error as CancellationError {
            // KaitoKit 0.11 の open は取消し済みの Task で CancellationError を投げる。不正な書庫とは区別する。
            throw error
        } catch {
            throw RewriterError.invalidArchive(String(describing: error))
        }
        let plan = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: format, reader: reader)
        return ArchiveRewriter(url: url, output: output, format: format, options: options,
                               source: source, reader: reader, names: plan.names,
                               hardLinkTargets: plan.hardLinkTargets, dataTargets: plan.dataTargets)
    }

    /// 全 entry を出力形式で表現できるかを、書庫を開かずに検査する。
    /// 未対応の LHA method・7z coder と、出力名・種別・日時・サイズの表現範囲を検査する。
    /// 一覧だけでは MacBinary envelope を検出できない。MacLHA の m member も受理する。
    /// 既存書庫の編集では、開いた reader に `probe(reader:format:)` を別途実行すること。
    /// 復号可否（password）、`WriterOptions`、原本の同一性は検査しない。暗号化の有無は
    /// `entries.contains(\.isEncrypted)` で呼出側が判断する。
    public static func probe(entries: [ArchiveEntry], format: ArchiveFormat) throws {
        _ = try ArchiveRepresentability.validateRepresentability(entries: entries, format: format)
    }

    /// `open` と同じ検査。reader は appleDoublePolicy .expose で開くこと。
    /// MacLHA の候補だけ stream の初期長を調べ、envelope を失う entry を拒否する。
    /// 全本文の復号・CRC、password、WriterOptions、原本の同一性は検査しない。
    public static func probe(reader: ArchiveReader, format: ArchiveFormat) throws {
        _ = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: format, reader: reader)
    }

    public func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        guard !additions.isEmpty else { return }
        try performAddition {
            if options.additionPlacement == .beginning {
                try preparedWriter().add(additions, events: events)
            } else {
                try addSequentially(additions, events: events)
            }
        }
    }

    public func add(contentsOf url: URL, as path: String) throws {
        try add(contentsOf: url, as: path, ownerIDs: nil)
    }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        try add(contentsOf: url, as: path, ownerIDs: ownerIDs, progress: nil)
    }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?,
                    progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try performAddition {
            try validateOwnerIDs(ownerIDs)
            if options.additionPlacement == .beginning {
                try preparedWriter().add(contentsOf: url, as: path, ownerIDs: ownerIDs, progress: progress)
            } else {
                let meter = progress.map { CommitProgressMeter(total: 0, progress: $0) }
                try meter?.start()
                let signature = try DiskSignature.capture(url)
                let name = try reserveAddition(path, directory: signature.isDirectory)
                additions.append(.disk(url, name, ownerIDs, signature))
                try meter?.finish()
            }
        }
    }

    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try performAddition {
            if options.additionPlacement == .beginning {
                try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions)
            } else {
                let name = try reserveAddition(path, directory: false)
                additions.append(.data(data, name, modificationDate, permissions))
            }
        }
    }

    public func addDirectory(_ path: String) throws {
        try addDirectory(path, modificationDate: nil, ownerIDs: nil)
    }

    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        try performAddition {
            try validateOwnerIDs(ownerIDs)
            if options.additionPlacement == .beginning {
                try preparedWriter().addDirectory(path, modificationDate: modificationDate, ownerIDs: ownerIDs)
            } else {
                let name = try reserveAddition(path, directory: true)
                additions.append(.directory(name, modificationDate, ownerIDs))
            }
        }
    }

    private func validateOwnerIDs(_ ids: ArchiveOwnerIDs?) throws {
        if ids != nil, format == .sevenZip || format == .lha { throw WriterError.unsupportedOption("ownerIDs") }
    }

    private func reserveAddition(_ path: String, directory: Bool) throws -> String {
        try Task.checkCancellation()
        let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: format)
        try ledger.reserve(name, directory: directory)
        return name
    }

    /// open 時の index を削除予約する。重複は一度だけ削除し、子孫は暗黙に削除しない。
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            try ledger.remove(indices, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }

    /// 子孫や symlink target は変更しない。削除済みの index は指定できない。
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try ledger.rename(index, to: path, format: format, appendedBy: writer)
            writerPathsNeedRefresh = true
        }
    }

    public func commit() throws { try commit(didCarry: nil) }

    /// 生き残る entry を運び、終端を書いて同期してから公開する。成功後の再呼出しは no-op。
    /// didCarry は各 entry の完了後に呼び、throw は取消と同じく部分出力を削除する。
    /// 置換後の metadata 復元でエラーになった場合、内容の置換は既に完了している。
    public func commit(didCarry: ((Int, Int) throws -> Void)? = nil) throws {
        try commit(progress: nil, didCarry: didCarry)
    }

    /// total = carry と退避の読取 + 記録した追加の読取 + 有界の圧縮待ち予算。
    /// 同期 callback は公開前に完了し、throw は元の error のまま操作を失敗させる。
    public func commit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?,
                       didCarry: ((Int, Int) throws -> Void)? = nil) throws {
        if state == .committed { return }
        var progressError: Error?
        do { try perform {
            // didCarry からの再入で、確定した carry 順序や名前集合を変更させない。
            state = .committing
            try checkUnchanged()
            let writer = try preparedWriter()
            // 予約名は add の検査専用。carry 自身との衝突は除き、追加済み名は残す。
            writer.replaceExistingPaths([])
            let survivors = reader.entries.filter { ledger.survives($0.index) }
            let neededTargets = Set(survivors.compactMap { entry -> Int? in
                guard let target = hardLinkTargets[entry.index], !isTar || ledger.removed.contains(target) else { return nil }
                return dataTargets[entry.index]
            })
            let meter: CommitProgressMeter?
            if let progress {
                meter = CommitProgressMeter(total: try commitBudget(survivors: survivors, neededTargets: neededTargets, writer: writer),
                                            progress: { update in
                    do { try progress(update) } catch { progressError = error; throw error }
                    guard self.state == .committing else { throw RewriterError.invalidState }
                })
                try meter?.start()
            } else { meter = nil }
            try carrySurvivors(survivors, neededTargets: neededTargets, writer: writer, meter: meter, didCarry: didCarry)
            try flushAdditions(writer: writer, meter: meter)
            let quarantine = output == nil ? try readQuarantine() : nil
            try checkUnchanged()
            try Task.checkCancellation()
            try writer.finishAdditions(meter: meter)
            try writer.finish()
            self.writer = nil
            try Task.checkCancellation()
            try checkUnchanged()
            try meter?.finish()
            try Task.checkCancellation()
            if meter != nil { try checkUnchanged() }
            if output == nil { try publish(quarantine: quarantine) }
            state = .committed
            cleanup()
        } } catch { throw progressError ?? error }
    }

    /// total = carry と退避の読取 + 記録した追加の読取 + 有界の圧縮待ち予算。
    private func commitBudget(survivors: [ArchiveEntry], neededTargets: Set<Int>, writer: ArchiveWriter) throws -> UInt64 {
        var reads: UInt64 = 0
        for entry in survivors { reads = try checkedAdd(reads, carryInputByteCount(entry)) }
        for index in neededTargets { reads = try checkedAdd(reads, reader.entries[index].uncompressedSize ?? 0) }
        for addition in additions {
            let count: UInt64
            switch addition {
            case let .disk(url, _, _, signature):
                count = signature.isDirectory ? try ArchiveWriter.inputByteCount(url) : signature.inputByteCount
            case let .data(data, _, _, _): count = UInt64(data.count)
            case .directory: count = 0
            }
            reads = try checkedAdd(reads, count)
        }
        let drain = min(try checkedAdd(reads, writer.pendingInputBytes), options.maximumPendingInputBytes(for: format))
        return try checkedAdd(reads, drain)
    }

    /// 生き残る entry を open 時の index 順に運ぶ。削除された hard link の参照先は先に退避し、didCarry は entry ごとに呼ぶ。
    private func carrySurvivors(_ survivors: [ArchiveEntry], neededTargets: Set<Int>, writer: ArchiveWriter,
                                meter: CommitProgressMeter?, didCarry: ((Int, Int) throws -> Void)?) throws {
        var buffered: [Int: BufferedEntry] = [:]
        var done = 0
        for entry in reader.entries.sorted(by: { $0.index < $1.index }) {
            guard ledger.survives(entry.index) || neededTargets.contains(entry.index) else { continue }
            try autoreleasepool {
                try Task.checkCancellation()
                do {
                    if entry.isEncrypted, reader.password == nil { throw KaitoError.passwordRequired }
                    if neededTargets.contains(entry.index) { buffered[entry.index] = try buffer(entry, meter: meter) }
                    if !ledger.survives(entry.index) { return }
                    try carry(entry, writer: writer, buffered: buffered, meter: meter)
                } catch let error as KaitoError {
                    throw ArchiveRepresentability.map(error, entry: entry.name)
                } catch WriterError.sourceChanged(let name) {
                    throw RewriterError.invalidArchive("entry のサイズが一致しません: \(name)")
                }
                done += 1
                try didCarry?(done, survivors.count)
            }
        }
    }

    /// 記録した追加を書く。disk と directory は batch にまとめ、data はその場で書く。
    private func flushAdditions(writer: ArchiveWriter, meter: CommitProgressMeter?) throws {
        var batch: [ArchiveAddition] = []
        var signatures: [DiskSignature?] = []
        func flush() throws {
            guard !batch.isEmpty else { return }
            // commit の既存のエラー契約は項目別の原因をそのまま返す。
            do { try writer.add(batch, expected: signatures, meter: meter, events: nil) }
            catch let error as ArchiveAdditionError { throw error.underlying }
            batch.removeAll(keepingCapacity: true)
            signatures.removeAll(keepingCapacity: true)
        }
        for addition in additions {
            try Task.checkCancellation()
            switch addition {
            case let .disk(url, path, ids, signature):
                batch.append(.init(path: path, source: .contents(of: url), ownerIDs: ids))
                signatures.append(signature)
            case let .data(data, path, date, mode):
                try flush()
                try writer.add(data: data, as: path, modificationDate: date, permissions: mode, meter: meter)
            case let .directory(path, date, ids):
                batch.append(.init(path: path, source: .directory(modificationDate: date), ownerIDs: ids))
                signatures.append(nil)
            }
        }
        try flush()
        additions.removeAll()
    }

    /// 一時出力で原本を置換し、mode と quarantine を戻す。
    private func publish(quarantine: Data?) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: destination!)
        try FileManager.default.setAttributes([.posixPermissions: source.mode], ofItemAtPath: url.path)
        if let quarantine {
            let status = quarantine.withUnsafeBytes {
                setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard status == 0 else { throw WriterError.io(operation: "restore quarantine", code: errno) }
        }
    }

    private var isTar: Bool { format.isTar }

    private func carryInputByteCount(_ entry: ArchiveEntry) -> UInt64 {
        if entry.kind == .directory { return 0 }
        if let target = hardLinkTargets[entry.index] {
            if isTar, !ledger.removed.contains(target) { return 0 }
            return reader.entries[dataTargets[entry.index]!].uncompressedSize ?? 0
        }
        if entry.kind == .symlink, entry.formatSpecific["linkPath"] != nil { return 0 }
        return entry.uncompressedSize ?? 0
    }

    private func carry(_ entry: ArchiveEntry, writer: ArchiveWriter, buffered: [Int: BufferedEntry],
                       meter: CommitProgressMeter?) throws {
        let owners: (UInt32, UInt32)? = options.carriedTarOwnerIDs == .keep && isTar
            ? (UInt32(entry.formatSpecific["uid"] ?? "") ?? 0, UInt32(entry.formatSpecific["gid"] ?? "") ?? 0) : nil
        func add(size: UInt64, hardLink: String? = nil, read: (Int) throws -> Data) throws {
            if let meter, carryInputByteCount(entry) > 0 {
                try writer.addEntry(path: ledger.finalName(entry.index), mode: ArchiveRepresentability.mode(for: entry), size: size,
                                    date: entry.modificationDate ?? Date(), atime: nil, owners: owners,
                                    hardLink: hardLink) { count in
                    let bytes = try read(count)
                    try meter.advance(UInt64(bytes.count))
                    return bytes
                }
            } else {
                try writer.addEntry(path: ledger.finalName(entry.index), mode: ArchiveRepresentability.mode(for: entry), size: size,
                                    date: entry.modificationDate ?? Date(), atime: nil, owners: owners,
                                    hardLink: hardLink, read: read)
            }
        }
        if entry.kind == .directory {
            try add(size: 0) { _ in Data() }
        } else if let target = hardLinkTargets[entry.index] {
            if isTar, !ledger.removed.contains(target) {
                try add(size: 0, hardLink: ledger.finalName(target)) { _ in Data() }
            } else {
                guard let payload = buffered[dataTargets[entry.index]!] else {
                    throw RewriterError.invalidArchive("hard link の参照先の内容がありません: \(entry.name)")
                }
                try withBuffered(payload) { size, read in try add(size: size, read: read) }
            }
        } else if entry.kind == .symlink, let target = entry.formatSpecific["linkPath"] {
            let data = Data(target.utf8)
            var offset = 0
            try add(size: UInt64(data.count)) { requested in
                let count = min(requested, data.count - offset)
                defer { offset += count }
                return data.subdata(in: offset..<(offset + count))
            }
        } else {
            if entry.kind == .symlink, entry.formatSpecific["linkTargetStoredAsData"] != "true" {
                throw RewriterError.invalidArchive("symlink の参照先がありません: \(entry.name)")
            }
            if let payload = buffered[entry.index] {
                try withBuffered(payload) { size, read in try add(size: size, read: read) }
            } else if let size = entry.uncompressedSize {
                let stream = try reader.stream(entry)
                try add(size: size) { try stream.readFully(upTo: min($0, IOChunk.size)) }
            } else {
                let payload = try buffer(entry)
                defer { try? FileManager.default.removeItem(at: payload.url) }
                try withBuffered(payload) { size, read in try add(size: size, read: read) }
            }
        }
    }

    private struct BufferedEntry { let url: URL; let size: UInt64 }

    // 不明サイズと hard link の参照先だけをディスクへ退避し、通常ファイルを readAll しない。
    private func buffer(_ entry: ArchiveEntry, meter: CommitProgressMeter? = nil) throws -> BufferedEntry {
        let url = workDirectory!.appendingPathComponent("entry-\(entry.index)-\(UUID().uuidString)")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: "create entry buffer", code: errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let stream = try reader.stream(entry)
        var size: UInt64 = 0
        while true {
            let chunk = try stream.readFully(upTo: IOChunk.size)
            if chunk.isEmpty { break }
            size = try checkedAdd(size, UInt64(chunk.count))
            try file.write(contentsOf: chunk)
            if entry.uncompressedSize != nil { try meter?.advance(UInt64(chunk.count)) }
        }
        if let expected = entry.uncompressedSize, size != expected { throw WriterError.sourceChanged(entry.name) }
        return BufferedEntry(url: url, size: size)
    }

    private func withBuffered(_ entry: BufferedEntry, body: (UInt64, (Int) throws -> Data) throws -> Void) throws {
        let file = try FileHandle(forReadingFrom: entry.url)
        defer { try? file.close() }
        try body(entry.size) {
            try Task.checkCancellation()
            return try FileRead.readChunk(file.fileDescriptor, upTo: min($0, IOChunk.size))
        }
    }

    private func preparedWriter() throws -> ArchiveWriter {
        if let writer {
            // 改名の予約中は索引だけ更新し、次の add の直前に writer の全名を同期する。
            if writerPathsNeedRefresh {
                writer.replaceExistingPaths(ledger.existingPaths)
                writerPathsNeedRefresh = false
            }
            return writer
        }
        try Task.checkCancellation()
        try checkUnchanged()
        let directory = (output ?? url).deletingLastPathComponent()
            .appendingPathComponent(".gyoshuku-rewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        workDirectory = directory
        let destination = output ?? directory.appendingPathComponent(url.lastPathComponent)
        let writer = try ArchiveWriter.create(url: destination, format: format, options: options)
        self.writer = writer
        self.destination = destination
        destinationHandle = try writer.duplicateOutput()
        if output == nil {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        writer.replaceExistingPaths(ledger.existingPaths)
        writerPathsNeedRefresh = false
        return writer
    }

    private func checkUnchanged() throws {
        do { try source.checkUnchanged(at: url) }
        catch { throw RewriterError.invalidArchive("原本が open 後に変更されています") }
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

    private func performAddition(_ body: () throws -> Void) throws {
        guard !additionsClosed else { throw RewriterError.invalidState }
        try perform(body)
    }

    private func perform(_ body: () throws -> Void) throws {
        guard state == .adding else { throw RewriterError.invalidState }
        do { try body() } catch {
            state = .failed
            cleanup()
            throw error
        }
    }

    private func cleanup() {
        if state != .committed, let destination, let destinationHandle {
            ArchiveOwnedFile.remove(url: destination, descriptor: destinationHandle.fileDescriptor)
        }
        writer = nil
        additions.removeAll()
        try? destinationHandle?.close()
        destinationHandle = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        destination = nil
    }
}
