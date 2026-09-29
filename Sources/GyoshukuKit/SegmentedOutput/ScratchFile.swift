import Foundation
private import Darwin

// 出力の隣に排他的に作り、空 inode の一致を確かめて直ちに unlink する。以後は fd だけを持ち、close で解放する。
// 圧縮 tar の splice 保存、追加の再配置と 7z folder の scratch、LHA の圧縮 spool が共有する。
final class ScratchFile {
    @TaskLocal static var testingFreeSpaceReserve: UInt64?
    @TaskLocal static var testingCreated: (@Sendable (Int32) -> Void)?
    let handle: FileHandle
    private(set) var length: UInt64 = 0
    var copySeconds = 0.0
    private var closed = false

    init(directory: URL, tag: String, pathExtension: String) throws {
        guard !tag.isEmpty, tag.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) else {
            throw WriterError.invalidPath(tag)
        }
        let url = directory.appendingPathComponent(".gyoshuku-\(tag)-\(UUID().uuidString).\(pathExtension)")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: "create scratch", code: errno) }
        guard ArchiveOwnedFile.matches(url: url, descriptor: fd), unlink(url.path) == 0 else {
            let code = errno
            ArchiveOwnedFile.remove(url: url, descriptor: fd)
            Darwin.close(fd)
            throw WriterError.io(operation: "unlink scratch", code: code)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        Self.testingCreated?(fd)
        try willWrite(0)
    }

    deinit { close() }

    func willWrite(_ count: Int) throws {
        let end = try checkedAdd(length, UInt64(count))
        // 固定の予備容量は要求しない。容量検査は故障注入時だけ。
        if let reserve = Self.testingFreeSpaceReserve {
            var space = statfs()
            guard fstatfs(handle.fileDescriptor, &space) == 0 else { throw WriterError.io(operation: "free space", code: errno) }
            let available = UInt64(space.f_bavail) * UInt64(space.f_bsize)
            guard available >= reserve else {
                throw WriterError.io(operation: "free space", code: ENOSPC)
            }
        }
        length = end
    }

    @discardableResult
    func append(_ bytes: Data) throws -> Range<UInt64> {
        let start = length
        try willWrite(bytes.count)
        try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(handle.fileDescriptor, bytes: $0, at: start) }
        return start..<length
    }

    func source() throws -> ArchiveFileSource { try ArchiveFileSource(duplicating: handle.fileDescriptor) }

    func forEachChunk(_ emit: (Data) throws -> Void) throws {
        try handle.seek(toOffset: 0)
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try FileRead.readChunk(handle.fileDescriptor, upTo: Int(min(UInt64(IOChunk.size), remaining)))
            guard !chunk.isEmpty else { throw WriterError.io(operation: "read scratch", code: EIO) }
            try emit(chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
