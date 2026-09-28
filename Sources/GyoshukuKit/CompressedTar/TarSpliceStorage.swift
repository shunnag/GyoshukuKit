import Foundation
private import Darwin

// 追加と literal だけを保存する。名前は空 inode の間に安全に外し、以後は fd だけを持つ。
final class TarSpliceStorage {
    @TaskLocal static var testingFreeSpaceReserve: UInt64?
    @TaskLocal static var testingCreated: (@Sendable (Int32) -> Void)?
    let handle: FileHandle
    let url: URL
    private(set) var written: UInt64 = 0

    init(directory: URL) throws {
        url = directory.appendingPathComponent(".gyoshuku-splice-\(UUID().uuidString).tar")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: "create splice storage", code: errno) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard ArchiveOwnedFile.matches(url: url, descriptor: fd), unlink(url.path) == 0 else {
            ArchiveOwnedFile.remove(url: url, descriptor: fd)
            throw WriterError.io(operation: "unlink splice storage", code: errno)
        }
        Self.testingCreated?(fd)
        try willWrite(0)
    }

    func willWrite(_ count: Int) throws {
        let end = try checkedAdd(written, UInt64(count))
        // 出力 volume の追加/literal に固定の予備容量は要求しない。容量検査は故障注入時だけ。
        if let reserve = Self.testingFreeSpaceReserve {
            var space = statfs()
            guard fstatfs(handle.fileDescriptor, &space) == 0 else { throw WriterError.io(operation: "free space", code: errno) }
            let available = UInt64(space.f_bavail) * UInt64(space.f_bsize)
            guard available >= reserve else {
                throw WriterError.io(operation: "free space", code: ENOSPC)
            }
        }
        written = end
    }

    func append(_ bytes: Data) throws -> Range<UInt64> {
        let start = written
        try willWrite(bytes.count)
        try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(handle.fileDescriptor, bytes: $0, at: start) }
        return start..<written
    }
    func source() throws -> ArchiveFileSource { try ArchiveFileSource(duplicating: handle.fileDescriptor) }
}
