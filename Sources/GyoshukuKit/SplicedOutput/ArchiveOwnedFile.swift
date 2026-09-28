import Foundation
internal import Darwin

// inode と stat の一致で「同じファイルか」「変わっていないか」を判定する。原本・snapshot・出力・scratch で共有する。
struct FileIdentity: Sendable {
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
    let identity: FileIdentity

    init(url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "lstat output", code: errno) }
        self.url = url
        identity = FileIdentity(info)
    }

    init(url: URL, descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw WriterError.io(operation: "fstat output", code: errno) }
        self.url = url
        identity = FileIdentity(info)
    }

    // FAT/exFAT は空 file ごとに上位範囲から降順の仮 inode を割り当てる。
    // 実体の cluster 番号（HFS+ の CNID / APFS の object ID も）は 2^63 未満。
    static func hasAssignedInode(_ inode: ino_t) -> Bool {
        inode < (ino_t(1) << 63)
    }

    static func matches(url: URL, descriptor: Int32) -> Bool {
        var opened = stat()
        var path = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_nlink > 0,
              lstat(url.path, &path) == 0, opened.st_dev == path.st_dev, opened.st_ino == path.st_ino,
              opened.st_mode & S_IFMT == path.st_mode & S_IFMT else { return false }
        if !hasAssignedInode(opened.st_ino) {
            // 仮値同士だけでは、rename された空 file とその跡の別 file を区別できない。
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &name) == 0 else { return false }
            let actual = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let canonical = realpath(url.path, nil) else { return false }
            defer { free(canonical) }
            guard String(decoding: actual, as: UTF8.self) == String(cString: canonical) else { return false }
        }
        return true
    }

    static func remove(url: URL, descriptor: Int32) {
        if matches(url: url, descriptor: descriptor) { _ = unlink(url.path) }
    }

    func remove() {
        var info = stat()
        if Self.hasAssignedInode(identity.inode), lstat(url.path, &info) == 0,
           Self.hasAssignedInode(info.st_ino), identity.matchesInode(info) { _ = unlink(url.path) }
    }
}
