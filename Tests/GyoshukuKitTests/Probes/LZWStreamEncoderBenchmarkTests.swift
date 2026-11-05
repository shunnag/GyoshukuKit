import Foundation
import XCTest
@testable import GyoshukuKit

final class LZWStreamEncoderBenchmarkTests: XCTestCase {
    func testDictionaryThroughput() throws {
        try OptInGate.flag("GYOSHUKU_LZW_BENCHMARK")
        #if DEBUG
        XCTFail("Run LZWStreamEncoderBenchmarkTests with -c release")
        #else
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["GYOSHUKU_LZW_BENCHMARK_REPEATS"] ?? "5") ?? 5)
        let inputs = [("text", LZMAEncoderCorpus.text(size: 4 << 20)),
                      ("binary", try Data(contentsOf: URL(fileURLWithPath: "/usr/lib/dyld"), options: .mappedIfSafe)),
                      ("random", TestCorpus.random(4 << 20))]
        TestSupport.report("LZW-BENCH\tcorpus\tmaxbits\tbytes\tbest_s\tbest_MBps\tmedian_s\tmedian_MBps")
        for (name, input) in inputs {
            for maxbits in [12, 16] {
                var expected: Data?
                var durations: [Double] = []
                for iteration in 0..<repeats {
                    let encoder = try LZWStreamEncoder(maxbits: maxbits)
                    var encoded = Data()
                    let start = ProcessInfo.processInfo.systemUptime
                    try encoder.write(input, finish: true) { encoded.append($0) }
                    durations.append(ProcessInfo.processInfo.systemUptime - start)
                    if let expected {
                        XCTAssertEqual(encoded, expected)
                    } else {
                        let reference = try ReferenceLZWStreamEncoder(maxbits: maxbits)
                        var referenceOutput = Data()
                        try reference.write(input, finish: true) { referenceOutput.append($0) }
                        XCTAssertEqual(encoded, referenceOutput)
                        expected = encoded
                    }
                    if iteration == 0 {
                        let directory = try TestSupport.directory("lzw-encoder-benchmark")
                        try encoded.write(to: directory.appendingPathComponent("\(name)-\(maxbits).Z"))
                    }
                }
                let sorted = durations.sorted()
                let best = sorted[0], median = sorted[sorted.count / 2]
                TestSupport.report(String(format: "LZW-BENCH\t%@\t%d\t%d\t%.6f\t%.3f\t%.6f\t%.3f",
                    name, maxbits, expected?.count ?? 0, best, Double(input.count) / 1_000_000 / best,
                    median, Double(input.count) / 1_000_000 / median))
            }
        }
        #endif
    }
}
