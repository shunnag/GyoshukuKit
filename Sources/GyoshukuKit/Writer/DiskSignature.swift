import Foundation
internal import Darwin

struct DiskSignature: Sendable {
    private let identity: ZipFileIdentity
    var isDirectory: Bool { identity.mode & S_IFMT == S_IFDIR }
    var inputByteCount: UInt64 { identity.mode & S_IFMT == S_IFREG ? UInt64(max(0, identity.size)) : 0 }

    init(_ info: stat) { identity = ZipFileIdentity(info) }

    func matches(_ info: stat) -> Bool {
        identity.matchesInode(info) && identity.mode == info.st_mode && identity.size == info.st_size
            && identity.seconds == info.st_mtimespec.tv_sec && identity.nanoseconds == info.st_mtimespec.tv_nsec
    }

    static func capture(_ url: URL) throws -> DiskSignature {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
        let signature = DiskSignature(info)
        switch info.st_mode & S_IFMT {
        case S_IFDIR, S_IFLNK: break
        case S_IFREG:
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw WriterError.io(operation: "open source", code: errno) }
            defer { Darwin.close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw WriterError.io(operation: "fstat source", code: errno) }
            guard signature.matches(opened), info.st_size >= 0 else { throw WriterError.sourceChanged(url.path) }
        default: throw WriterError.unsupportedFileType(url.path)
        }
        return signature
    }
}
