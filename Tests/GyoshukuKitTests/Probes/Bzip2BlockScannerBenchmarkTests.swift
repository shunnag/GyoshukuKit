import Foundation
import XCTest
@testable import GyoshukuKit

final class Bzip2BlockScannerBenchmarkTests: XCTestCase {
    func testThroughput() throws {
        try OptInGate.flag("GYOSHUKU_BZIP2_BENCHMARK")
        #if DEBUG
        XCTFail("Run Bzip2BlockScannerBenchmarkTests with -c release")
        #else
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["GYOSHUKU_BZIP2_BENCHMARK_REPEATS"] ?? "20") ?? 20)
        let inputs = [
            ("text", LZMAEncoderCorpus.text(size: 4 << 20)),
            ("alternating", Data((0..<(4 << 20)).map { UInt8($0 & 1) })),
            ("runs127", Data((0..<(4 << 20)).map { UInt8(($0 / 127) & 0xFF) })),
            ("repeated", Data(repeating: 0x5A, count: 4 << 20)),
            ("random", TestCorpus.random(4 << 20)),
        ]
        TestSupport.report("BZIP2-SCAN\tcorpus\tlevel\tblocks\tbest_s\tbest_MBps\tmedian_s\tmedian_MBps")
        for (name, input) in inputs {
            for level in [1, 9] {
                var expectedBlocks: Int?
                var durations: [Double] = []
                for _ in 0..<repeats {
                    var scanner = Bzip2BlockScanner(level: level)
                    let start = ProcessInfo.processInfo.systemUptime
                    let cut = scanner.scan(input, target: Int.max)
                    durations.append(ProcessInfo.processInfo.systemUptime - start)
                    XCTAssertNil(cut)
                    XCTAssertEqual(scanner.position, input.count)
                    if let expectedBlocks {
                        XCTAssertEqual(scanner.finalBlockCount, expectedBlocks)
                    } else {
                        expectedBlocks = scanner.finalBlockCount
                    }
                }
                let sorted = durations.sorted()
                let best = sorted[0], median = sorted[sorted.count / 2]
                TestSupport.report(String(format: "BZIP2-SCAN\t%@\t%d\t%d\t%.9f\t%.3f\t%.9f\t%.3f",
                    name, level, expectedBlocks ?? 0, best, Double(input.count) / 1_000_000 / best,
                    median, Double(input.count) / 1_000_000 / median))
            }
        }
        #endif
    }
}
