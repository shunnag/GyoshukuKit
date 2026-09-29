import Foundation
internal import Darwin

/// 出力 file の inode を、作成から公開（adopt）または削除（discard）まで所有する。
/// path と fd の一致は ArchiveOwnedFile.matches の FAT/exFAT 規則（fresh fstat/lstat）で検査し、
/// 失敗時は自分の inode だけを消す。SegmentedArchiveOutput と CompressedTarSpliceOutput が一つずつ持つ。
/// clone 出力は open の前に expectClone で所有を登録し、open した fd がその inode であることを確かめてから handle を持つ。
/// 検査に失敗した fd は handle に入れないので、discard は他人の file を消さない。
final class OwnedOutputFile {
    let url: URL
    private(set) var handle: FileHandle?
    private var owned: ArchiveOwnedFile?

    init(url: URL) { self.url = url }

    /// open 済みの descriptor。open 前・adopt 後の呼出しは呼出側の順序違反で、trap する。
    var descriptor: Int32 { handle!.fileDescriptor }

    /// fclonefileat で作った file の identity を先に所有する。次の open が fd をこの inode と照合する。
    func expectClone(_ cloned: ArchiveOwnedFile) { owned = cloned }

    /// flags は呼出側の従来の値をそのまま渡す（新規作成は O_CREAT | O_EXCL、clone 済みの file を開くならそれ無し）。
    /// 開いた直後に path と fd の一致を検査する。
    func open(flags: Int32, operation: String) throws {
        let fd = Darwin.open(url.path, flags, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: operation, code: errno) }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let owned {
            var info = stat()
            guard fstat(fd, &info) == 0, owned.identity.matchesInode(info) else { throw UpdaterError.sourceChanged }
        }
        handle = opened
        try checkOutput()
    }

    /// 開いている fd が今も url の実体であることを確かめる。
    func checkOutput() throws {
        guard let handle else { throw UpdaterError.invalidState }
        guard ArchiveOwnedFile.matches(url: url, descriptor: handle.fileDescriptor) else {
            throw UpdaterError.sourceChanged
        }
    }

    func synchronize() throws { try handle!.synchronize() }
    func truncate(atOffset offset: UInt64) throws { try handle!.truncate(atOffset: offset) }

    /// 同じ commit の中で出力を捨てて作り直す前段。開いている inode を消して閉じる。discard と違い close の失敗は投げる。
    func reset() throws {
        if let handle {
            ArchiveOwnedFile.remove(url: url, descriptor: handle.fileDescriptor)
            try handle.close()
        }
        handle = nil
        owned = nil
    }

    /// fstat で公開時の identity を取り、fd を閉じて inode の所有だけを残す。
    @discardableResult
    func adopt() throws -> ArchiveOwnedFile {
        let adopted = try ArchiveOwnedFile(url: url, descriptor: handle!.fileDescriptor)
        owned = adopted
        try handle!.close()
        handle = nil
        return adopted
    }

    /// 開いていれば path と fd の一致を確かめて unlink し、閉じた後は identity の一致で unlink する。二重呼出しは無害。
    func discard() {
        if let handle { ArchiveOwnedFile.remove(url: url, descriptor: handle.fileDescriptor) }
        else { owned?.remove() }
        try? handle?.close()
        handle = nil
        owned = nil
    }
}
