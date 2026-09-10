import Foundation
private import Darwin
internal import KaitoKit

/// ZIP / ZIP64 の追加・削除・改名。生き残る entry は再圧縮しない。
/// thread-safe ではない。呼出側は同じ書庫への操作も直列化する。
/// add は clone に書き、削除・改名は予約する。commit 成功で原本を置換する。
/// 失敗後は再利用できない。deinit は未 commit の clone を削除する。
public final class ArchiveUpdater {
    private let url: URL
    private let source: ZipUpdateSource
    private let layout: ZipUpdateLayout
    private let reader: ArchiveReader?
    private var removed: Set<Int> = []
    private var renamed: [Int: String] = [:]
    // 公開 API を増やさず、nil とコピー途中の I/O 失敗も検証できる取得境界。
    var rawRecord: (ArchiveReader, ArchiveEntry) throws -> RawEntryRecord? = { try $0.rawRecord(of: $1) }
    private var writer: ArchiveWriter?
    private var replacementDirectory: URL?
    private var replacement: URL?
    private enum State { case adding, committed, failed }
    private var state = State.adding

    private init(url: URL, source: ZipUpdateSource, layout: ZipUpdateLayout, reader: ArchiveReader?) {
        self.url = url
        self.source = source
        self.layout = layout
        self.reader = reader
    }

    deinit { cleanup() }

    public static func open(url: URL) throws -> ArchiveUpdater {
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        // 正規の空 ZIP / ZIP64 は検証済み終端だけで完結し、解釈する entry がない。
        // KaitoKit の形式判定が空 ZIP64 を認識しない場合も、新しい API は必要ない。
        if layout.count == 0 {
            try source.checkUnchanged(at: url)
            return ArchiveUpdater(url: url, source: source, layout: layout, reader: nil)
        }
        // 再圧縮しないので展開量の制限は不要。entry 数と metadata の既定上限は維持する。
        let reader = try ArchiveReader.open(source: source, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max)))
        guard reader.format == .zip, UInt64(reader.entries.count) == layout.count else {
            throw UpdaterError.invalidArchive("KaitoKit の entry 数と EOCD が一致しません")
        }
        try source.checkUnchanged(at: url)
        return ArchiveUpdater(url: url, source: source, layout: layout, reader: reader)
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

    /// open 時のゼロ始まり index を削除予約する。重複指定は一度だけ削除する。
    /// directory の子孫は暗黙に削除しない。予約後も他 entry の index は変わらない。
    public func remove(entriesAt indices: [Int]) throws {
        try perform {
            for index in indices { try validateIndex(index) }
            removed.formUnion(indices)
            for index in indices { renamed.removeValue(forKey: index) }
            writer?.replaceExistingPaths(existingPaths)
        }
    }

    /// open 時の index を改名予約する。新しい名前は UTF-8 / NFC、directory は末尾 /。
    /// 削除済み entry は指定できず、子孫の改名や symlink target の変更は行わない。
    public func rename(entryAt index: Int, to path: String) throws {
        try perform {
            try validateIndex(index)
            guard !removed.contains(index), let reader else { throw UpdaterError.invalidEntryIndex(index) }
            let directory = reader.entries[index].kind == .directory
            let name = try ArchiveWriter.normalizedPath(path, directory: directory)
            let key = directory ? String(name.dropLast()) : name
            let otherPaths = reader.entries.filter { $0.index != index && !removed.contains($0.index) }
                .map { (renamed[$0.index] ?? $0.name, $0.kind == .directory) } + (writer?.appendedPaths ?? [])
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

    private func validateIndex(_ index: Int) throws {
        guard index >= 0, UInt64(index) < layout.count else { throw UpdaterError.invalidEntryIndex(index) }
    }

    private var existingPaths: [(String, Bool)] {
        (reader?.entries ?? []).filter { !removed.contains($0.index) }
            .map { (renamed[$0.index] ?? $0.name, $0.kind == .directory) }
    }

    /// 終端を書いて同期し、原本を atomic replace する。成功後の再呼出しは no-op。
    /// 置換後の metadata 復元でエラーになった場合、内容の置換は既に完了している。
    public func commit() throws {
        if state == .committed { return }
        try perform {
            try source.checkUnchanged(at: url)
            let rebuild = !removed.isEmpty || !renamed.isEmpty
            if let writer {
                try writer.finish(existingCount: layout.count, comment: layout.comment) { emit in
                    var position = layout.centralOffset
                    var remaining = layout.centralSize
                    while remaining > 0 {
                        let count = Int(min(remaining, 256 * 1024))
                        try emit(source.bytes(at: position, count: count))
                        position += UInt64(count)
                        remaining -= UInt64(count)
                    }
                }
                self.writer = nil
                if rebuild {
                    // 先に追加した record も rawRecord で運ぶ。完成した clone の APFS snapshot を
                    // 読取元に分け、同じファイルの読み書きによる上書きを避ける。
                    let staged = replacementDirectory!.appendingPathComponent("appended.zip")
                    try FileManager.default.copyItem(at: replacement!, to: staged)
                    let stagedSource = try ZipUpdateSource(url: staged)
                    let stagedLayout = try ZipUpdateLayout(source: stagedSource)
                    let stagedReader = try ArchiveReader.open(source: stagedSource, options: ReaderOptions(
                        limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max)))
                    try rebuildArchive(source: stagedSource, layout: stagedLayout, reader: stagedReader)
                }
            } else if rebuild, let reader {
                try prepareClone()
                try rebuildArchive(source: source, layout: layout, reader: reader)
            }
            if let replacement {
                let quarantine = try readQuarantine()
                try source.checkUnchanged(at: url)
                try Task.checkCancellation()
                _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
                // replacement の mode が勝つため、置換の直後に原本の mode を戻す。
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

    private func rebuildArchive(source: ZipUpdateSource, layout: ZipUpdateLayout, reader: ArchiveReader) throws {
        let output = try FileHandle(forUpdating: replacement!)
        defer { try? output.close() }
        try ZipRebuild.write(source: source, layout: layout, reader: reader, output: output,
                             removed: removed, renamed: renamed, rawRecord: rawRecord)
    }

    // add がなければ削除・改名の commit まで clone を遅延する。
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer { return writer }
        try prepareClone()
        let output = try FileHandle(forUpdating: replacement!)
        var info = stat()
        guard fstat(output.fileDescriptor, &info) == 0 else {
            throw WriterError.io(operation: "fstat clone", code: errno)
        }
        let writer = ArchiveWriter(output: output, identity: (info.st_dev, info.st_ino), format: .zip, options: WriterOptions())
        self.writer = writer
        try writer.prepareAppend(at: layout.centralOffset, existingPaths: existingPaths)
        return writer
    }

    private func prepareClone() throws {
        if replacement != nil { return }
        try Task.checkCancellation()
        try source.checkUnchanged(at: url)
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: url, create: true)
        replacementDirectory = directory
        let clone = directory.appendingPathComponent("archive.zip")
        replacement = clone
        try manager.copyItem(at: url, to: clone)
        try source.checkUnchanged(at: url)
        // clone の作業中は mode を 0600 に限定する。原本の mode は変更しない。
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clone.path)
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
        writer = nil
        if let replacementDirectory { try? FileManager.default.removeItem(at: replacementDirectory) }
        replacementDirectory = nil
        replacement = nil
    }
}
