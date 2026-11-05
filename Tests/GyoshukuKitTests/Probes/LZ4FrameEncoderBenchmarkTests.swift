import Foundation
import XCTest
@testable import GyoshukuKit

final class LZ4FrameEncoderBenchmarkTests: XCTestCase {
    func testSingleThreadBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_LZ4_BENCHMARK")
        #if DEBUG
        XCTFail("Run LZ4FrameEncoderBenchmarkTests with -c release")
        #else
        let directory = try TestSupport.directory("lz4-encoder-benchmark")
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["GYOSHUKU_LZ4_BENCHMARK_REPEATS"] ?? "5") ?? 5)
        let corpora = Set((environment["GYOSHUKU_LZ4_BENCHMARK_CORPORA"] ?? "text,random")
            .split(separator: ",").map(String.init))
        let inputs = [("text", LZMAEncoderCorpus.text(size: 16 << 20)), ("random", TestCorpus.random(16 << 20))]
        TestSupport.report("LZ4-BENCH\tcorpus\tbytes\tbest_s\tbest_MBps\tmedian_s\tmedian_MBps")
        for (name, input) in inputs where corpora.contains(name) {
            var reference: Data?
            var durations: [Double] = []
            for iteration in 0..<repeats {
                let encoder = try LZ4FrameEncoder(contentSize: UInt64(input.count), blockChecksums: true, threads: 1)
                var encoded = Data()
                let start = ProcessInfo.processInfo.systemUptime
                try encoder.write(input, finish: true) { encoded.append($0) }
                durations.append(ProcessInfo.processInfo.systemUptime - start)
                if let reference { XCTAssertEqual(encoded, reference) }
                else {
                    reference = encoded
                    let url = directory.appendingPathComponent("\(name).lz4")
                    try encoded.write(to: url)
                    try StreamEncoderTestSupport.assertKaito(url, equals: input)
                }
            }
            let sorted = durations.sorted()
            let best = sorted[0], median = sorted[sorted.count / 2]
            TestSupport.report(String(format: "LZ4-BENCH\t%@\t%d\t%.6f\t%.3f\t%.6f\t%.3f",
                name, reference?.count ?? 0, best, Double(input.count) / 1_000_000 / best,
                median, Double(input.count) / 1_000_000 / median))
        }
        #endif
    }
}
