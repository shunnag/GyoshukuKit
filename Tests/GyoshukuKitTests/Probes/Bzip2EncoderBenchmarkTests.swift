import Foundation
import XCTest
@testable import GyoshukuKit

final class Bzip2EncoderBenchmarkTests: XCTestCase {
    func testThroughput() throws {
        try OptInGate.flag("GYOSHUKU_BZIP2_BENCHMARK")
        #if DEBUG
        XCTFail("Run Bzip2EncoderBenchmarkTests with -c release")
        #else
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["GYOSHUKU_BZIP2_BENCHMARK_REPEATS"] ?? "3") ?? 3)
        let inputs = [
            ("text", LZMAEncoderCorpus.text(size: 4 << 20)),
            ("runs127", Data((0..<(4 << 20)).map { UInt8(($0 / 127) & 0xFF) })),
            ("repeated", Data(repeating: 0x5A, count: 4 << 20)),
        ]
        TestSupport.report("BZIP2-ENC\tcorpus\tlevel\tbytes\tbest_s\tbest_MBps\tmedian_s\tmedian_MBps")
        for (name, input) in inputs {
            for level in [1, 9] {
                let expected = try Bzip2StreamEncoder.encode(input, level: level)
                var durations: [Double] = []
                for _ in 0..<repeats {
                    var encoded = Data()
                    let start = ProcessInfo.processInfo.systemUptime
                    let encoder = try ParallelBzip2StreamEncoder(level: level, threads: 1, size: 0)
                    try encoder.write(input, finish: true) { encoded.append($0) }
                    durations.append(ProcessInfo.processInfo.systemUptime - start)
                    XCTAssertEqual(encoded, expected)
                }
                let sorted = durations.sorted()
                let best = sorted[0], median = sorted[sorted.count / 2]
                TestSupport.report(String(format: "BZIP2-ENC\t%@\t%d\t%d\t%.9f\t%.3f\t%.9f\t%.3f",
                    name, level, expected.count, best, Double(input.count) / 1_000_000 / best,
                    median, Double(input.count) / 1_000_000 / median))
            }
        }
        #endif
    }
}
