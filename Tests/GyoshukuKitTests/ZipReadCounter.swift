import Foundation
import Synchronization
@testable import GyoshukuKit

// Public open/probe/commit paths, including appended.zip, share this descriptor boundary.
// Task-local observation keeps concurrent tests isolated; the tally is synchronized.
final class ZipReadCounter: Sendable {
    private let reads = Mutex<[Range<UInt64>]>([])

    var ranges: [Range<UInt64>] { reads.withLock { $0 } }
    var byteCount: UInt64 { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    func measure<T>(_ body: () throws -> T) rethrows -> T {
        try ZipUpdateSource.$readObserver.withValue({ _, offset, count in
            self.reads.withLock { $0.append(offset..<(offset + UInt64(count))) }
        }, operation: body)
    }
}
