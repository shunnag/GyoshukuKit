import Foundation

/// ディスク追加や明示的な directory に指定する数値の所有者。
public struct ArchiveOwnerIDs: Sendable, Equatable, Hashable {
    public var user: UInt32
    public var group: UInt32
    public init(user: UInt32, group: UInt32) { self.user = user; self.group = group }
}

/// 書庫の追加・削除・改名と公開の共通境界。index は open 時の entryNames に対応する。
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
public protocol ArchiveEditing: AnyObject {
    var entryNames: [String] { get }
    func add(contentsOf url: URL, as path: String) throws
    /// nil でなければ設定より優先し、directory の全子孫にも同じ ID を使う。
    func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws
    func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws
    func addDirectory(_ path: String) throws
    /// mode 0755。日時の nil は現在時刻、ID の nil は形式の既定値。
    func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws
    func remove(entriesAt indices: [Int]) throws
    func rename(entryAt index: Int, to path: String) throws
    func commit() throws
}

/// 既存項目の暗号化を open 時の出力設定へそろえる予約を持つ editor。
public protocol ArchiveReencrypting: ArchiveEditing {
    func reencryptExistingEntries(currentPassword: String?) throws
}

extension ArchiveEditing {
    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        guard ownerIDs == nil else { throw WriterError.unsupportedOption("ownerIDs") }
        try add(contentsOf: url, as: path)
    }

    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        guard modificationDate == nil, ownerIDs == nil else { throw WriterError.unsupportedOption("addDirectory") }
        try addDirectory(path)
    }
}
