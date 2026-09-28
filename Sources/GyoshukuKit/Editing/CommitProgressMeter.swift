import Foundation

// commit の byte 進捗を ArchiveUpdater.CommitProgress として報告する二つの計器。
// ZipCommitMeter は struct で、ZIP の commit が一回分の byte 数を値として複製し、中断後に複製から再開する。
// CommitProgressMeter は class で、7z / tar / LHA の spliced output と writer が一つの session を共有する。
struct ZipCommitMeter {
    var completedBytes: UInt64 = 0
    let totalBytes: UInt64
    private var notified: UInt64 = 0
    static let interval: UInt64 = 4 * 1024 * 1024

    init(totalBytes: UInt64) { self.totalBytes = totalBytes }

    mutating func wrote(_ count: Int, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        completedBytes += UInt64(count)
        if let progress, completedBytes - notified >= Self.interval {
            try progress(.init(completedBytes: completedBytes, totalBytes: totalBytes))
            notified = completedBytes
        }
    }

    func finish(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try progress?(.init(completedBytes: completedBytes,
                            totalBytes: completedBytes == totalBytes ? totalBytes : completedBytes))
    }
}

final class CommitProgressMeter {
    let total: UInt64
    private(set) var completed: UInt64 = 0
    private var notified: UInt64 = 0
    private var finished = false
    private let progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?

    init(total: UInt64, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) {
        self.total = total
        self.progress = progress
    }
    func start() throws { try progress?(.init(completedBytes: 0, totalBytes: total)) }
    func advance(_ count: UInt64) throws {
        try Task.checkCancellation()
        completed += min(count, total - completed)
        if completed - notified >= ZipCommitMeter.interval, completed < total {
            notified = completed
            try progress?(.init(completedBytes: completed, totalBytes: total))
        }
    }
    func finish() throws {
        guard !finished else { return }
        finished = true
        completed = total
        try progress?(.init(completedBytes: total, totalBytes: total))
    }
}
