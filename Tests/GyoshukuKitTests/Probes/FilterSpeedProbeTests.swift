import Foundation
import XCTest
@testable import GyoshukuKit

// 小さい局所計測。release build でだけ速度を比較し、既定では実行しない。
final class FilterSpeedProbeTests: XCTestCase {
    func testDeltaCRC16AndLZWThroughputWhenEnabled() throws {
        try OptInGate.flag("GYOSHUKU_FILTER_SPEED_PROBE")
        let input = TestCorpus.random(4 << 20)
        for distance in [1, 4, 256] {
            measure("Delta-\(distance)-old", count: input.count) {
                UInt64(ReferenceSevenZipFilterEncoder(.delta(distance)).push(input, final: true).last ?? 0)
            }
            measure("Delta-\(distance)-new", count: input.count) {
                UInt64(SevenZipFilterEncoder(.delta(distance)).push(input, final: true).last ?? 0)
            }
        }
        measure("CRC16-old", count: input.count) { UInt64(ReferenceLHACRC16.update(0, input)) }
        measure("CRC16-new", count: input.count) { UInt64(LHACRC16.update(0, input)) }
        let lzwInput = input.prefix(1 << 20)
        try measure("LZW16-old", count: lzwInput.count) {
            let encoder = try ReferenceLZWStreamEncoder()
            var count: UInt64 = 0
            try encoder.write(lzwInput, finish: true) { count += UInt64($0.count) }
            return count
        }
        try measure("LZW16-new", count: lzwInput.count) {
            let encoder = try LZWStreamEncoder()
            var count: UInt64 = 0
            try encoder.write(lzwInput, finish: true) { count += UInt64($0.count) }
            return count
        }
        measure("LH5-append-old", count: input.count) {
            var bits = ReferenceLH5Bits()
            bits.write(5, count: 3)
            bits.append(input, remainder: .init(value: 0, count: 0))
            return UInt64(bits.finish().last ?? 0)
        }
        measure("LH5-append-new", count: input.count) {
            var bits = LH5Encoder.Bits()
            bits.write(5, count: 3)
            bits.append(input, remainder: .init(value: 0, count: 0))
            return UInt64(bits.finish().last ?? 0)
        }
    }

    private func measure(_ name: String, count: Int, body: () throws -> UInt64) rethrows {
        var best = Double.infinity, checksum: UInt64 = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            checksum &+= try body()
            let elapsed = start.duration(to: .now).components
            best = min(best, Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
        }
        TestSupport.report("FILTER_SPEED\t\(name)\t\(String(format: "%.1f", Double(count) / best / 1_000_000)) MB/s\tchecksum=\(checksum)")
    }
}
