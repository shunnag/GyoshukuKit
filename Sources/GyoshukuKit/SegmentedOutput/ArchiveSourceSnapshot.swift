import Foundation
internal import Darwin

// 形式に依存せず、開いた原本の descriptor から snapshot を作る。tar updater も共有する。
final class ArchiveSourceSnapshot {
    @TaskLocal static var testingCloneError: Int32?
    let original: ArchiveFileSource
    let source: ArchiveFileSource
    let originalURL: URL
    let snapshot: ArchiveOwnedFile?

    init(url: URL, directory: URL, pathExtension: String, disablesClone: Bool = false) throws {
        originalURL = url
        original = try ArchiveFileSource(url: url)
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
            let cloned = try ArchiveFileSource(url: target)
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
        try FileRead.validateFileURL(output)
        var info = stat()
        guard stat(output.deletingLastPathComponent().path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(output.path, &info) != 0, errno == ENOENT else { throw WriterError.invalidPath(output.path) }
    }
}
