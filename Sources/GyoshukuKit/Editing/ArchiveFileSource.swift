import Foundation
private import Darwin
internal import KaitoKit

// 原本・snapshot・scratch の descriptor を KaitoKit の reader とコピー経路で共有する。pread のみなので cursor は共有しない。
// 全形式の updater と rewriter が使う。
final class ArchiveFileSource: ByteSource {
    // descriptor 境界の I/O 量を検証する内部 hook。並行テスト間で観測を共有しない。
    @TaskLocal static var readObserver: (@Sendable (Int32, UInt64, Int) -> Void)?
    let descriptor: Int32
    let length: UInt64
    let identity: FileIdentity
    let flags: UInt32

    init(url: URL) throws {
        try FileRead.validateFileURL(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WriterError.io(operation: "open archive", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            Darwin.close(fd)
            throw UpdaterError.invalidArchive("通常ファイルではありません")
        }
        descriptor = fd
        identity = FileIdentity(info)
        flags = info.st_flags
        length = UInt64(info.st_size)
    }

    // 出力や scratch のパスが置換されても、所有する inode から読み続ける。
    init(duplicating original: Int32) throws {
        let fd = fcntl(original, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw WriterError.io(operation: "dup source", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            Darwin.close(fd)
            throw UpdaterError.invalidArchive("通常ファイルではありません")
        }
        descriptor = fd
        identity = FileIdentity(info)
        flags = info.st_flags
        length = UInt64(info.st_size)
    }

    deinit { Darwin.close(descriptor) }

    var mode: UInt16 { UInt16(identity.mode & 0o7777) }

    func checkUnchanged(at url: URL) throws {
        try identity.checkUnchanged(at: url)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        let actual = try FileRead.pread(descriptor, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
                                        at: offset, operation: "pread archive")
        Self.readObserver?(descriptor, offset, actual)
        return actual
    }

    func bytes(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= length, UInt64(count) <= length - offset else {
            throw UpdaterError.invalidArchive("終端構造がファイル範囲外です")
        }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { try readExactly(into: $0, at: offset) }
        return result
    }

    // copy の固定長 scratch を再利用し、短い pread も全範囲を満たすまで継続する。
    func readExactly(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws {
        let count = buffer.count
        guard offset <= length, UInt64(count) <= length - offset else {
            throw UpdaterError.invalidArchive("終端構造がファイル範囲外です")
        }
        var filled = 0
        while filled < count {
            let actual = try read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled..<count]),
                                  at: offset + UInt64(filled))
            guard actual > 0 else { throw UpdaterError.sourceChanged }
            filled += actual
        }
    }
}

/// 試験と旧来の呼出しのための名前。新しい code は ArchiveFileSource を使う。
typealias ZipUpdateSource = ArchiveFileSource
