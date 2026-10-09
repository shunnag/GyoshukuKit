import Foundation
import XCTest
@testable import GyoshukuKit

/// release専用。入力準備とbyte照合は計測外、初期化・join・compactは計測に含める。
final class LZMAMultithreadedBenchmarkTests: XCTestCase {
    func testSequentialVersusMultithreadedBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_LZMA_MT_BENCHMARK")
        #if DEBUG
        XCTFail("Run LZMAMultithreadedBenchmarkTests with -c release")
        #else
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, OptInGate.integer("GYOSHUKU_LZMA_MT_BENCHMARK_REPEATS", default: 3))
        let binaryURL = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        var corpora: [(String, String, Data)] = [
            ("text", "LZMAEncoderCorpus.text", LZMAEncoderCorpus.text(size: 4 << 20)),
            ("binary", binaryURL.path, try Data(contentsOf: binaryURL)),
            ("random", "xorshift64star:D137923A6E259B41", TestCorpus.random(16 << 20))
        ]
        if let path = environment["GYOSHUKU_LZMA_MT_BENCHMARK_FILE"] {
            corpora.append(("file", path, try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        for (name, source, input) in corpora {
            var samples = [[Double](), [Double]()]
            var expected: Data?
            for iteration in 0..<repeats {
                for threads in iteration.isMultiple(of: 2) ? [1, 2] : [2, 1] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let output = try LZMAEncoder.encode(input, properties: .preset(6), finderThreads: threads)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                    samples[threads - 1].append(elapsed)
                    if let expected { XCTAssertEqual(output, expected, name) } else { expected = output }
                }
            }
            let sequential = samples[0].min()!, parallel = samples[1].min()!
            let result: [String: Any] = ["corpus": name, "source": source, "level": 6,
                "input_bytes": input.count, "output_bytes": expected!.count, "repeats": repeats,
                "sequential_seconds": sequential, "mt_seconds": parallel,
                "sequential_MBps": Double(input.count) / 1_000_000 / sequential,
                "mt_MBps": Double(input.count) / 1_000_000 / parallel, "speedup": sequential / parallel,
                "sequential_samples": samples[0], "mt_samples": samples[1]]
            let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            TestSupport.report("LZMA-MT-BENCH\t" + String(decoding: json, as: UTF8.self))
        }
        #endif
    }
}
