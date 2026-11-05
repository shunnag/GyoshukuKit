import Foundation
import XCTest
@testable import GyoshukuKit

final class LH5EncoderBenchmarkTests: XCTestCase {
    func testSingleThreadBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_LH5_BENCHMARK")
        #if DEBUG
        XCTFail("Run LH5EncoderBenchmarkTests with -c release")
        #else
        let directory = try TestSupport.directory("lh5-encoder-benchmark")
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["GYOSHUKU_LH5_BENCHMARK_REPEATS"] ?? "3") ?? 3)
        let levels = environment["GYOSHUKU_LH5_BENCHMARK_LEVELS"]?.split(separator: ",").compactMap { Int($0) }
            .filter { (1...9).contains($0) } ?? [1, 6, 9]
        let corpora = Set((environment["GYOSHUKU_LH5_BENCHMARK_CORPORA"] ?? "text,binary,random")
            .split(separator: ",").map(String.init))
        let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/lib/dyld"), options: .mappedIfSafe)
        let inputs = [("text", LZMAEncoderCorpus.text(size: 4 << 20)),
                      ("binary", binary), ("random", TestCorpus.random(4 << 20))]
        TestSupport.report("LH5-BENCH\tcorpus\tlevel\tbytes\tbest_s\tbest_MBps\tmedian_s\tmedian_MBps")
        for (name, input) in inputs where corpora.contains(name) {
            for level in levels {
                let configuration = LH5Encoder.Configuration(level: level)
                var reference: Data?
                var durations: [Double] = []
                for iteration in 0..<repeats {
                    let start = ProcessInfo.processInfo.systemUptime
                    let encoded = try LH5Encoder.encode(input, configuration: configuration)
                    durations.append(ProcessInfo.processInfo.systemUptime - start)
                    if let reference { XCTAssertEqual(encoded, reference) }
                    else {
                        reference = encoded
                        _ = try LH5Stream(encoded, size: input.count)
                    }
                    if iteration == 0 {
                        try encoded.write(to: directory.appendingPathComponent("\(name)-\(level).lh5"))
                    }
                }
                let sorted = durations.sorted()
                let best = sorted[0], median = sorted[sorted.count / 2]
                let bytes = reference?.count ?? 0
                TestSupport.report(String(format: "LH5-BENCH\t%@\t%d\t%d\t%.6f\t%.3f\t%.6f\t%.3f",
                    name, level, bytes, best, Double(input.count) / 1_000_000 / best,
                    median, Double(input.count) / 1_000_000 / median))
            }
        }
        #endif
    }
}
