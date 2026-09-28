import Foundation
internal import KaitoKit

/// tar・圧縮 tar・7z・LHA の updater と ArchiveRewriter が共有する、削除・改名の予約と名前の衝突検査の台帳。
/// index は open 時の entry の位置（KaitoKit の ArchiveEntry.index と一致する）。names は正規化した出力名で、
/// 空文字列の root directory は予約に載せない。予約は最初に使う時点の生き残る名前から作り、以後は削除・改名と
/// writer が追加した名前を反映する。thread-safe ではなく、操作が失敗した後の台帳は使わない。
final class EntryEditLedger {
    let names: [String]
    private let isDirectory: [Bool]
    private(set) var removed: Set<Int> = []
    private(set) var renamed: [Int: String] = [:]
    private lazy var reservations = EditPathReservations(existingPaths)
    private var indexedAppendCount = 0

    init(names: [String], entries: [ArchiveEntry]) {
        self.names = names
        isDirectory = entries.map { $0.kind == .directory }
    }

    /// 改名後の名前。改名していなければ open 時の正規化した名前。
    func finalName(_ index: Int) -> String { renamed[index] ?? names[index] }
    /// 削除されず、名前が空でない（出力に残る）entry か。
    func survives(_ index: Int) -> Bool { !removed.contains(index) && !finalName(index).isEmpty }

    /// 生き残る entry の（最終名, directory か）。writer の衝突検査に渡す。
    var existingPaths: [(String, Bool)] {
        names.indices.compactMap { index in
            let name = finalName(index)
            return removed.contains(index) || name.isEmpty ? nil : (name, isDirectory[index])
        }
    }

    func validateIndex(_ index: Int) throws {
        guard isDirectory.indices.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
    }

    /// すべての index を検査してから削除を予約する。重複や削除済みの index は一度だけ扱う。
    func remove(_ indices: [Int], appendedBy writer: ArchiveWriter?) throws {
        for index in indices { try validateIndex(index) }
        indexAppendedPaths(writer)
        for index in indices where !removed.contains(index) {
            let name = finalName(index)
            if !name.isEmpty { reservations.remove(name, directory: isDirectory[index]) }
            removed.insert(index); renamed.removeValue(forKey: index)
        }
    }

    /// 削除済みの index は指定できない。path を format の規則で正規化し、衝突しなければ予約して返す。
    @discardableResult
    func rename(_ index: Int, to path: String, format: ArchiveFormat, appendedBy writer: ArchiveWriter?) throws -> String {
        try validateIndex(index)
        guard !removed.contains(index) else { throw UpdaterError.invalidEntryIndex(index) }
        let directory = isDirectory[index]
        let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: format)
        indexAppendedPaths(writer)
        let old = finalName(index)
        if !old.isEmpty { reservations.remove(old, directory: directory) }
        try reserve(name, directory: directory)
        renamed[index] = name
        return name
    }

    /// 正規化済みの name が生き残る名前・予約済みの名前と衝突しなければ予約する。
    func reserve(_ name: String, directory: Bool) throws {
        try reservations.validate(name, directory: directory)
        reservations.insert(name, directory: directory)
    }

    // writer が前回から追加した名前を予約に加える。
    private func indexAppendedPaths(_ writer: ArchiveWriter?) {
        for (name, directory) in (writer?.appendedPaths ?? []).dropFirst(indexedAppendCount) {
            reservations.insert(name, directory: directory)
        }
        indexedAppendCount = writer?.appendedPaths.count ?? indexedAppendCount
    }
}
