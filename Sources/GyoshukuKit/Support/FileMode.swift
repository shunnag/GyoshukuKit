// st_mode の種別（S_IFMT）を書庫の mode 欄と同じ UInt16 で扱う。ZIP の外部属性、tar / 7z / LHA の mode 欄で共有する。
enum FileMode {
    static let typeMask: UInt16 = 0o170000
    static let regular: UInt16 = 0o100000
    static let directory: UInt16 = 0o040000
    static let symlink: UInt16 = 0o120000
    /// 明示的に追加する directory の mode（drwxr-xr-x）。
    static let defaultDirectory: UInt16 = 0o040755
    /// ディスクの symlink を書庫に置くときの mode（lrwxr-xr-x）。
    static let defaultSymlink: UInt16 = 0o120755
}

extension UInt16 {
    var isRegularFileMode: Bool { self & FileMode.typeMask == FileMode.regular }
    var isDirectoryMode: Bool { self & FileMode.typeMask == FileMode.directory }
}
