import Foundation
private import Darwin
private import KaitoKit

/// ZIP / ZIP64 に entry を追加する。既存 local record と CD の byte は変更しない。
/// thread-safe ではない。呼出側は同じ書庫への操作も直列化する。
/// add は clone に書き、commit 成功で原本を置換する。失敗後は再利用できない。
/// deinit は未 commit の clone を削除する。削除・改名は扱わない。
public final class ArchiveUpdater {
    private let url: URL
    private let source: ZipUpdateSource
    private let layout: ZipUpdateLayout
    private let existingPaths: [(String, Bool)]
    private var writer: ArchiveWriter?
    private var replacementDirectory: URL?
    private var replacement: URL?
    private enum State { case adding, committed, failed }
    private var state = State.adding

    private init(url: URL, source: ZipUpdateSource, layout: ZipUpdateLayout, paths: [(String, Bool)]) {
        self.url = url
        self.source = source
        self.layout = layout
        self.existingPaths = paths
    }

    deinit { cleanup() }

    public static func open(url: URL) throws -> ArchiveUpdater {
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        // 正規の空 ZIP / ZIP64 は検証済み終端だけで完結し、解釈する entry がない。
        // KaitoKit の形式判定が空 ZIP64 を認識しない場合も、新しい API は必要ない。
        if layout.count == 0 {
            try source.checkUnchanged(at: url)
            return ArchiveUpdater(url: url, source: source, layout: layout, paths: [])
        }
        // 再圧縮しないので展開量の制限は不要。entry 数と metadata の既定上限は維持する。
        let reader = try ArchiveReader.open(source: source, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max)))
        guard reader.format == .zip, UInt64(reader.entries.count) == layout.count else {
            throw UpdaterError.invalidArchive("KaitoKit の entry 数と EOCD が一致しません")
        }
        try source.checkUnchanged(at: url)
        return ArchiveUpdater(url: url, source: source, layout: layout,
                              paths: reader.entries.map { ($0.name, $0.kind == .directory) })
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

    /// 終端を書いて同期し、原本を atomic replace する。成功後の再呼出しは no-op。
    /// 置換後の metadata 復元でエラーになった場合、内容の置換は既に完了している。
    public func commit() throws {
        if state == .committed { return }
        try perform {
            try source.checkUnchanged(at: url)
            if let writer, let replacement {
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
                let quarantine = try readQuarantine()
                try source.checkUnchanged(at: url)
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

    // 最初の add まで clone を遅延する。FileManager.copyItem は APFS 上で clone を使う。
    private func preparedWriter() throws -> ArchiveWriter {
        if let writer { return writer }
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
        let output = try FileHandle(forUpdating: clone)
        var info = stat()
        guard fstat(output.fileDescriptor, &info) == 0 else {
            throw WriterError.io(operation: "fstat clone", code: errno)
        }
        let writer = ArchiveWriter(output: output, identity: (info.st_dev, info.st_ino), format: .zip, options: WriterOptions())
        self.writer = writer
        try writer.prepareAppend(at: layout.centralOffset, existingPaths: existingPaths)
        return writer
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
