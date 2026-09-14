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

/// KaitoKit が読める書庫を全 entry の再圧縮で編集・変換する。出力は暗号化しない。
/// thread-safe ではない。呼出側は同じ書庫への操作も直列化する。
/// add は直ちに出力へ書き、生き残る entry は commit 時に index 昇順で運ぶ。
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
    private let source: ZipUpdateSource
    private let reader: ArchiveReader
    private let names: [String]
    private let hardLinkTargets: [Int: Int]
    private let dataTargets: [Int: Int]
    private var removed: Set<Int> = []
    private var renamed: [Int: String] = [:]
    private var writer: ArchiveWriter?
    private var workDirectory: URL?
    private var destination: URL?
    private var destinationIdentity: (dev_t, ino_t)?
    private enum State { case adding, committing, committed, failed }
    private var state = State.adding
    private static let chunkSize = 256 * 1024

    public let sourceFormat: KaitoKit.ArchiveFormat
    public let hasEncryptedEntries: Bool

    /// 予約済みの削除・改名や追加を反映せず、常に open 時の名前を返す。
    public var entryNames: [String] { reader.entries.map(\.name) }

    private init(url: URL, output: URL?, format: ArchiveFormat, options: WriterOptions,
                 source: ZipUpdateSource, reader: ArchiveReader, names: [String],
                 hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        self.url = url
        self.output = output
        self.format = format
        self.options = options
        self.source = source
        self.reader = reader
        self.names = names
        self.hardLinkTargets = hardLinkTargets
        self.dataTargets = dataTargets
        sourceFormat = reader.format
        hasEncryptedEntries = reader.entries.contains { $0.isEncrypted }
    }

    deinit { cleanup() }

    /// output が nil なら同じ volume 上の一時出力で原本を置換し、指定時は新規作成する。
    /// 全 entry の表現可能性を検証するまで、出力や作業ディレクトリを作らない。
    public static func open(url: URL, password: String? = nil, output: URL? = nil,
                            format: ArchiveFormat, options: WriterOptions = WriterOptions()) throws -> ArchiveRewriter {
        let source: ZipUpdateSource
        let reader: ArchiveReader
        do {
            source = try ZipUpdateSource(url: url)
            reader = try ArchiveReader.open(url: url, options: ReaderOptions(
                limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max),
                password: password))
            try source.checkUnchanged(at: url)
        } catch let error as KaitoError {
            throw map(error, entry: nil)
        } catch {
            throw RewriterError.invalidArchive(String(describing: error))
        }
        var names: [String] = []
        var hardLinkTargets: [Int: Int] = [:]
        var dataTargets: [Int: Int] = [:]
        for entry in reader.entries {
            func refuse(_ reason: String) -> RewriterError {
                .unrepresentable(entry: entry.name, reason: reason)
            }
            let carried = entry.pathComponents.drop(while: { $0 == "." }).joined(separator: "/")
            let name: String
            // ./ や . の directory は書庫の root。改名された時だけ通常の directory として運ぶ。
            do {
                name = carried.isEmpty && entry.kind == .directory ? ""
                    : try ArchiveWriter.normalizedPath(carried, directory: entry.kind == .directory)
            } catch { throw refuse("出力名に空の要素・禁止文字・不正な相対パスが含まれています") }
            guard entry.kind != .other else { throw refuse("この entry 種別は書き込めません") }
            if entry.kind == .symlink, format == .lha { throw refuse("LHA は symlink を保存できません") }
            if entry.kind == .hardlink {
                guard let text = entry.formatSpecific["hardLinkTargetIndex"], let index = Int(text),
                      index >= 0, index < entry.index, reader.entries.indices.contains(index),
                      reader.entries[index].kind == .file || dataTargets[index] != nil else {
                    throw refuse("hard link の参照先が欠けているか、先行する通常ファイルではありません")
                }
                hardLinkTargets[entry.index] = index
                dataTargets[entry.index] = dataTargets[index] ?? index
            }
            let date = entry.modificationDate ?? Date()
            do {
                switch format {
                case .zip: _ = try ZipRecords.timestamp(date)
                case .sevenZip: _ = try SevenZipRecords.timestamp(date)
                case .lha: _ = try LHARecords.timestamp(date)
                case .tar, .tarGzip: _ = try TarRecords.timestamp(date)
                }
            } catch { throw refuse("更新日時が出力形式の表現範囲外です") }
            if format == .lha {
                // writer と同じ CP932 往復・header 長・サイズの検査を、出力作成前に行う。
                let size = dataTargets[entry.index].map { reader.entries[$0].uncompressedSize }
                    ?? entry.uncompressedSize
                do {
                    _ = try LHARecords.Entry(name: name, mode: mode(for: entry), size: size ?? 0, date: date)
                } catch { throw refuse("LHA の CP932 名・header 長・32 bit サイズで表現できません") }
            }
            names.append(name)
        }
        return ArchiveRewriter(url: url, output: output, format: format, options: options,
                               source: source, reader: reader, names: names,
                               hardLinkTargets: hardLinkTargets, dataTargets: dataTargets)
    }

    public func add(contentsOf url: URL, as path: String) throws {
        try perform { try preparedWriter().add(contentsOf: url, as: path) }
    }

    public func add(data: Data, as path: String, modificationDate: Date? = nil, permissions: UInt16? = nil) throws {
        try perform {
            try preparedWriter().add(data: data, as: path, modificationDate: modificationDate, permissions: permissions)
        }
    }

    public func addDirectory(_ path: String) throws {
        try perform { try preparedWriter().addDirectory(path) }
    }

    /// open 時の index を削除予約する。重複は一度だけ削除し、子孫は暗黙に削除しない。
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            for index in indices { try validateIndex(index) }
            removed.formUnion(indices)
            for index in indices { renamed.removeValue(forKey: index) }
            writer?.replaceExistingPaths(existingPaths)
        }
    }

    /// 子孫や symlink target は変更しない。削除済みの index は指定できない。
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
            let directory = reader.entries[index].kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory)
            let key = directory ? String(name.dropLast()) : name
            let otherPaths = reader.entries.filter { $0.index != index && survives($0.index) }
                .map { (finalName($0.index), $0.kind == .directory) } + (writer?.appendedPaths ?? [])
            for (other, isDirectory) in otherPaths {
                let otherKey = other.hasSuffix("/") ? String(other.dropLast()) : other
                guard key != otherKey else { throw WriterError.duplicatePath(name) }
                guard !(!directory && otherKey.hasPrefix(key + "/")),
                      !(!isDirectory && key.hasPrefix(otherKey + "/")) else { throw WriterError.invalidPath(name) }
            }
            renamed[index] = name
            writer?.replaceExistingPaths(existingPaths)
        }
    }

    public func commit() throws { try commit(didCarry: nil) }

    /// 生き残る entry を運び、終端を書いて同期してから公開する。成功後の再呼出しは no-op。
    /// didCarry は各 entry の完了後に呼び、throw は取消と同じく部分出力を削除する。
    /// 置換後の metadata 復元でエラーになった場合、内容の置換は既に完了している。
    public func commit(didCarry: ((Int, Int) throws -> Void)? = nil) throws {
        if state == .committed { return }
        try perform {
            // didCarry からの再入で、確定した carry 順序や名前集合を変更させない。
            state = .committing
            try checkUnchanged()
            let writer = try preparedWriter()
            // 予約名は add の検査専用。carry 自身との衝突は除き、追加済み名は残す。
            writer.replaceExistingPaths([])
            let survivors = reader.entries.filter { survives($0.index) }
            let neededTargets = Set(survivors.compactMap { entry -> Int? in
                guard let target = hardLinkTargets[entry.index], !isTar || removed.contains(target) else { return nil }
                return dataTargets[entry.index]
            })
            var buffered: [Int: BufferedEntry] = [:]
            var done = 0
            for entry in reader.entries.sorted(by: { $0.index < $1.index }) {
                guard survives(entry.index) || neededTargets.contains(entry.index) else { continue }
                try Task.checkCancellation()
                do {
                    if entry.isEncrypted, reader.password == nil { throw KaitoError.passwordRequired }
                    if neededTargets.contains(entry.index) { buffered[entry.index] = try buffer(entry) }
                    if !survives(entry.index) { continue }
                    try carry(entry, writer: writer, buffered: buffered)
                } catch let error as KaitoError {
                    throw Self.map(error, entry: entry.name)
                } catch WriterError.sourceChanged(let name) {
                    throw RewriterError.invalidArchive("entry のサイズが一致しません: \(name)")
                }
                done += 1
                try didCarry?(done, survivors.count)
            }
            let quarantine = output == nil ? try readQuarantine() : nil
            try checkUnchanged()
            try Task.checkCancellation()
            try writer.finish()
            self.writer = nil
            try Task.checkCancellation()
            try checkUnchanged()
            if output == nil {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: destination!)
                try FileManager.default.setAttributes([.posixPermissions: source.mode], ofItemAtPath: url.path)
                if let quarantine {
                    let status = quarantine.withUnsafeBytes {
                        setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                    }
                    guard status == 0 else { throw WriterError.io(operation: "restore quarantine", code: errno) }
                }
            }
            state = .committed
            cleanup()
        }
    }

    private var isTar: Bool { format == .tar || format == .tarGzip }
    private func finalName(_ index: Int) -> String { renamed[index] ?? names[index] }
    private func survives(_ index: Int) -> Bool { !removed.contains(index) && !finalName(index).isEmpty }
    private var existingPaths: [(String, Bool)] {
        reader.entries.filter { survives($0.index) }.map { (finalName($0.index), $0.kind == .directory) }
    }

    private func validateIndex(_ index: Int) throws {
        guard reader.entries.indices.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
    }

    private static func mode(for entry: ArchiveEntry) -> UInt16 {
        let type: UInt16 = entry.kind == .directory ? 0o40000 : entry.kind == .symlink ? 0o120000 : 0o100000
        return type | ((entry.posixPermissions ?? (entry.kind == .directory ? 0o755 : 0o644)) & 0o7777)
    }

    private func carry(_ entry: ArchiveEntry, writer: ArchiveWriter, buffered: [Int: BufferedEntry]) throws {
        let owners: (UInt32, UInt32)? = options.preserveOwnerIDs && isTar
            ? (UInt32(entry.formatSpecific["uid"] ?? "") ?? 0, UInt32(entry.formatSpecific["gid"] ?? "") ?? 0) : nil
        func add(size: UInt64, hardLink: String? = nil, read: (Int) throws -> Data) throws {
            try writer.addEntry(path: finalName(entry.index), mode: Self.mode(for: entry), size: size,
                                date: entry.modificationDate ?? Date(), atime: nil, owners: owners,
                                hardLink: hardLink, read: read)
        }
        if entry.kind == .directory {
            try add(size: 0) { _ in Data() }
        } else if let target = hardLinkTargets[entry.index] {
            if isTar, !removed.contains(target) {
                try add(size: 0, hardLink: finalName(target)) { _ in Data() }
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
                try add(size: size) { try Self.read(stream, count: $0) }
            } else {
                let payload = try buffer(entry)
                defer { try? FileManager.default.removeItem(at: payload.url) }
                try withBuffered(payload) { size, read in try add(size: size, read: read) }
            }
        }
    }

    private struct BufferedEntry { let url: URL; let size: UInt64 }

    // 不明サイズと hard link の参照先だけをディスクへ退避し、通常ファイルを readAll しない。
    private func buffer(_ entry: ArchiveEntry) throws -> BufferedEntry {
        let url = workDirectory!.appendingPathComponent("entry-\(entry.index)-\(UUID().uuidString)")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: "create entry buffer", code: errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let stream = try reader.stream(entry)
        var size: UInt64 = 0
        while true {
            let chunk = try Self.read(stream, count: Self.chunkSize)
            if chunk.isEmpty { break }
            size = try checkedAdd(size, UInt64(chunk.count))
            try file.write(contentsOf: chunk)
        }
        if let expected = entry.uncompressedSize, size != expected { throw WriterError.sourceChanged(entry.name) }
        return BufferedEntry(url: url, size: size)
    }

    private func withBuffered(_ entry: BufferedEntry, body: (UInt64, (Int) throws -> Data) throws -> Void) throws {
        let file = try FileHandle(forReadingFrom: entry.url)
        defer { try? file.close() }
        try body(entry.size) {
            try Task.checkCancellation()
            return try file.read(upToCount: min($0, Self.chunkSize)) ?? Data()
        }
    }

    private static func read(_ stream: EntryStream, count: Int) throws -> Data {
        var data = Data(count: min(count, chunkSize))
        var filled = 0
        let capacity = data.count
        try data.withUnsafeMutableBytes { storage in
            while filled < capacity {
                try Task.checkCancellation()
                let count = try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: storage[filled..<capacity]))
                if count == 0 { break }
                filled += count
            }
        }
        data.count = filled
        return data
    }

    private func preparedWriter() throws -> ArchiveWriter {
        if let writer { return writer }
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
        destinationIdentity = writer.outputIdentity
        if output == nil {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        writer.replaceExistingPaths(existingPaths)
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

    private static func map(_ error: KaitoError, entry: String?) -> RewriterError {
        switch error {
        case .passwordRequired, .wrongPassword: .password(entry: entry)
        default: .invalidArchive(String(describing: error))
        }
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
        writer = nil
        if state != .committed, let destination, let identity = destinationIdentity {
            var info = stat()
            if lstat(destination.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 {
                _ = unlink(destination.path)
            }
        }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        destination = nil
        destinationIdentity = nil
    }
}
