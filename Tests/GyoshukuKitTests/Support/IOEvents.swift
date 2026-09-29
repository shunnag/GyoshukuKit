import Foundation
import Darwin
import Synchronization
@_spi(Testing) @testable import GyoshukuKit

// 製品の I/O の観測点（task-local）に渡して、読み書きの位置と量を記録する。
// - `ArchiveFileSource.$readObserver` ← `read`：元書庫からの pread（descriptor と inode も残す）
// - `ZipCopyEngine.$writeObserver` ← `write`：ZIP の更新が出力へ書いた範囲
// - `SplicedArchiveOutput.$verificationReadObserver` ← `write`：出力の自己照合で読み直した範囲
// task-local なので並行する試験の記録は混ざらない。記録そのものは Mutex で守る。
final class IOEvents: Sendable {
    struct Event: Sendable { let descriptor: Int32; let offset: UInt64; let count: Int; let inode: UInt64 }
    private let storage = Mutex<[Event]>([])
    var events: [Event] { storage.withLock { $0 } }
    var bytes: UInt64 { events.reduce(0) { $0 + UInt64($1.count) } }
    var ranges: [Range<UInt64>] { events.map { $0.offset..<($0.offset + UInt64($0.count)) } }
    func read(_ descriptor: Int32, _ offset: UInt64, _ count: Int) {
        var info = stat()
        _ = fstat(descriptor, &info)
        storage.withLock { $0.append(.init(descriptor: descriptor, offset: offset, count: count, inode: UInt64(info.st_ino))) }
    }
    func write(_ offset: UInt64, _ count: Int) {
        storage.withLock { $0.append(.init(descriptor: -1, offset: offset, count: count, inode: 0)) }
    }

    /// `body` の間の元書庫からの読み出しを記録する。
    func measureReads<T>(_ body: () throws -> T) rethrows -> T {
        try ArchiveFileSource.$readObserver.withValue(read, operation: body)
    }
}
