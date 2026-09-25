import Foundation
internal import Darwin

struct ZipFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let seconds: Int
    let nanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        mode = info.st_mode
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }

    func matchesInode(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }

    func checkUnchanged(at url: URL) throws {
        var info = stat()
        // Finder の xattr 更新でも変わる ctime は比較しない。
        guard lstat(url.path, &info) == 0, matchesInode(info), size == info.st_size,
              mode == info.st_mode, seconds == info.st_mtimespec.tv_sec,
              nanoseconds == info.st_mtimespec.tv_nsec else { throw UpdaterError.sourceChanged }
    }
}

struct ArchiveOwnedFile {
    let url: URL
    let identity: ZipFileIdentity

    init(url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "lstat output", code: errno) }
        self.url = url
        identity = ZipFileIdentity(info)
    }

    init(url: URL, descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
        self.url = url
        identity = ZipFileIdentity(info)
    }

    func remove() {
        var info = stat()
        if lstat(url.path, &info) == 0, identity.matchesInode(info) { _ = unlink(url.path) }
    }
}

// 形式に依存せず、開いた原本の descriptor から snapshot を作る。tar updater も共有する。
final class ArchiveSourceSnapshot {
    @TaskLocal static var testingCloneError: Int32?
    let original: ZipUpdateSource
    let source: ZipUpdateSource
    let originalURL: URL
    let snapshot: ArchiveOwnedFile?

    init(url: URL, directory: URL, pathExtension: String, disablesClone: Bool = false) throws {
        originalURL = url
        original = try ZipUpdateSource(url: url)
        let refused = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard original.flags & refused == 0 else { throw WriterError.io(operation: "source flags", code: EPERM) }
        let target = directory.appendingPathComponent(".gyoshuku-source-\(UUID().uuidString).\(pathExtension)")
        let status: Int32
        if disablesClone { errno = ENOTSUP; status = -1 }
        else if let code = Self.testingCloneError { errno = code; status = -1 }
        else { status = fclonefileat(original.descriptor, AT_FDCWD, target.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) }
        if status != 0 {
            let code = errno
            if code != EEXIST { (try? ArchiveOwnedFile(url: target))?.remove() }
            guard code == ENOTSUP || code == EXDEV else { throw WriterError.io(operation: "clone source", code: code) }
            try original.checkUnchanged(at: url)
            source = original
            snapshot = nil
            return
        }
        let owned = try ArchiveOwnedFile(url: target)
        do {
            let cloned = try ZipUpdateSource(url: target)
            var info = stat()
            guard fstat(cloned.descriptor, &info) == 0, owned.identity.matchesInode(info) else {
                throw UpdaterError.sourceChanged
            }
            if info.st_flags != 0, fchflags(cloned.descriptor, 0) != 0 {
                throw WriterError.io(operation: "clear snapshot flags", code: errno)
            }
            try original.checkUnchanged(at: url)
            source = cloned
            snapshot = owned
        } catch { owned.remove(); throw error }
    }

    deinit { cleanup() }

    func checkUnchanged() throws {
        try original.checkUnchanged(at: originalURL)
        if let snapshot { try source.checkUnchanged(at: snapshot.url) }
    }

    func cleanup() { snapshot?.remove() }

    static func validateOutput(_ output: URL) throws {
        guard output.isFileURL, !output.path.contains("\0") else { throw WriterError.invalidPath(output.absoluteString) }
        var info = stat()
        guard stat(output.deletingLastPathComponent().path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(output.path, &info) != 0, errno == ENOENT else { throw WriterError.invalidPath(output.path) }
    }
}
