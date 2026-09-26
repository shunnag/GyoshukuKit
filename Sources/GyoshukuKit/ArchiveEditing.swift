import Foundation

/// ディスク追加や明示的な directory に指定する数値の所有者。
public struct ArchiveOwnerIDs: Sendable, Equatable, Hashable {
    public var user: UInt32
    public var group: UInt32
    public init(user: UInt32, group: UInt32) { self.user = user; self.group = group }
}

/// 一括追加の一項目。配列の順が書庫内の順序になる。
public struct ArchiveAddition: Sendable {
    public enum Source: Sendable {
        /// symlink は辿らず、directory は再帰する。
        case contents(of: URL)
        /// mode 0755 の空 directory。nil の日時は現在時刻。
        case directory(modificationDate: Date?)
    }
    public var path: String
    public var source: Source
    public var ownerIDs: ArchiveOwnerIDs?
    public init(path: String, source: Source, ownerIDs: ArchiveOwnerIDs? = nil) {
        self.path = path; self.source = source; self.ownerIDs = ownerIDs
    }

    var sourceURL: URL? {
        if case let .contents(url) = source { return url }
        return nil
    }
}

public enum ArchiveAdditionEvent: Sendable, Equatable {
    /// この項目の最初の syscall より前。throw した項目は開かない。
    case willStart(index: Int)
    /// 追加元の byte。項目ごとに混ざらない昇順の session。
    case progress(index: Int, ArchiveUpdater.CommitProgress)
    /// 入力を受け取った時点。圧縮の完了とは限らない。
    case didFinish(index: Int)
}

/// 最小の失敗 index と原因。取消しと events の throw はこの型で包まない。
public struct ArchiveAdditionError: Error, Sendable {
    public let index: Int
    public let path: String
    /// 再帰中の失敗ではその子孫。明示的な directory は nil。
    public let sourceURL: URL?
    public let underlying: any Error
}

// callback の error は種類にかかわらず元のまま返す。
struct AdditionEventFailure: Error { let underlying: any Error }

func additionFailure(_ error: any Error, index: Int, addition: ArchiveAddition,
                     sourceURL: URL? = nil) -> any Error {
    if error is CancellationError || error is AdditionEventFailure || error is ArchiveAdditionError { return error }
    return ArchiveAdditionError(index: index, path: addition.path,
                                sourceURL: sourceURL ?? addition.sourceURL, underlying: error)
}

func additionEvent(_ event: ArchiveAdditionEvent, _ events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
    do { try events?(event) } catch { throw AdditionEventFailure(underlying: error) }
}

/// 書庫の追加・削除・改名と公開の共通境界。index は open 時の entryNames に対応する。
/// thread-safe ではない。同じ instance の操作は呼出側が直列化する。
public protocol ArchiveEditing: AnyObject {
    var entryNames: [String] { get }
    /// 同じ項目を項目別 API で追加した場合と byte 一致する。events は呼出しの thread で同期通知する。
    /// 有界の willStart の先行を許すが、progress と didFinish は index の昇順。
    /// 失敗は editor を failed にし、最小の失敗 index を返す。events の throw と取消しは包まない。
    func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws
    func add(contentsOf url: URL, as path: String) throws
    /// nil でなければ設定より優先し、directory の全子孫にも同じ ID を使う。
    func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws
    /// この呼出しで読む通常ファイルの byte を同期通知する。total は最初に固定する。
    /// 圧縮の完了前に最後の通知が来ることがあり、残りは finishAdditions が報告する。
    /// callback は保持せず、throw は操作の失敗としてそのまま返す。
    func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?,
             progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws
    /// 追加を閉じ、受取済みの入力を終端を書かずに出力する。total は待ちの入力 byte。
    /// 以後の追加は invalidState（instance は失敗にしない）。削除・改名・commit は可能。
    /// 呼ばずに commit しても出力は同じ。二度目は (0, 0) を二度通知する。
    func finishAdditions(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws
    /// true は追加元を add 時には読まず、commit で読む editor。
    var readsAdditionsDuringCommit: Bool { get }
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
    public func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        try addSequentially(additions, events: events)
    }

    func addSequentially(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
        do {
            for (index, addition) in additions.enumerated() {
                do {
                    try additionEvent(.willStart(index: index), events)
                    try Task.checkCancellation()
                    switch addition.source {
                    case let .contents(url):
                        try add(contentsOf: url, as: addition.path, ownerIDs: addition.ownerIDs, progress: events.map { events in
                            { try additionEvent(.progress(index: index, $0), events) }
                        })
                    case let .directory(date):
                        try additionEvent(.progress(index: index, .init(completedBytes: 0, totalBytes: 0)), events)
                        try addDirectory(addition.path, modificationDate: date, ownerIDs: addition.ownerIDs)
                        try additionEvent(.progress(index: index, .init(completedBytes: 0, totalBytes: 0)), events)
                    }
                    try additionEvent(.didFinish(index: index), events)
                } catch { throw additionFailure(error, index: index, addition: addition) }
            }
            try Task.checkCancellation()
        } catch let error as AdditionEventFailure { throw error.underlying }
    }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?,
                    progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try progress?(.init(completedBytes: 0, totalBytes: 0))
        if let ownerIDs { try add(contentsOf: url, as: path, ownerIDs: ownerIDs) }
        else { try add(contentsOf: url, as: path) }
        try progress?(.init(completedBytes: 0, totalBytes: 0))
    }

    public func finishAdditions(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try progress?(.init(completedBytes: 0, totalBytes: 0))
        try progress?(.init(completedBytes: 0, totalBytes: 0))
    }

    public var readsAdditionsDuringCommit: Bool { false }

    public func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {
        guard ownerIDs == nil else { throw WriterError.unsupportedOption("ownerIDs") }
        try add(contentsOf: url, as: path)
    }

    public func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
        guard modificationDate == nil, ownerIDs == nil else { throw WriterError.unsupportedOption("addDirectory") }
        try addDirectory(path)
    }
}
