import Foundation

/// 書庫の追加・削除・改名と公開の共通境界。index は open 時の entryNames に対応する。
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
public protocol ArchiveEditing: AnyObject {
    var entryNames: [String] { get }
    func add(contentsOf url: URL, as path: String) throws
    func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws
    func addDirectory(_ path: String) throws
    func remove(entriesAt indices: [Int]) throws
    func rename(entryAt index: Int, to path: String) throws
    func commit() throws
}
