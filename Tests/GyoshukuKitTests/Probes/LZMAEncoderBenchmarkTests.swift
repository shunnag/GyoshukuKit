// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation
import XCTest
@testable import GyoshukuKit

/// release でだけ計測する。入力準備と外部 oracle の復号は計測区間外。
final class LZMAEncoderBenchmarkTests: XCTestCase {
    func testSingleThreadBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_LZMA_BENCHMARK")
        #if DEBUG
        XCTFail("Run LZMAEncoderBenchmarkTests with -c release")
        return
        #else
        let directory = try TestSupport.directory("lzma-encoder-benchmark")
        let text = LZMAEncoderCorpus.text(size: 4 << 20)
        let binary = try binaryCorpus()
        TestSupport.report("LZMA-BENCH-CORPUS\ttext\t\(text.count)")
        TestSupport.report("LZMA-BENCH-CORPUS\tbinary\t\(binary.count)")
        TestSupport.report("LZMA-BENCH\tcorpus\tlevel\tencoder\tbytes\tMB/s\tseconds")
        for (name, input) in [("text", text), ("binary", binary)] {
            let url = directory.appendingPathComponent(name + ".bin")
            try input.write(to: url)
            var results: [Int: (bytes: Int, speed: Double, xzBytes: Int, xzSpeed: Double)] = [:]
            for level in [1, 6, 9] {
                let p = LZMAEncoderProperties.preset(level)
                let start = ProcessInfo.processInfo.systemUptime
                let bytes = try LZMA2Encoder.encode(input, properties: p)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let speed = Double(input.count) / 1_000_000 / elapsed
                report(name, level, "swift", bytes.count, elapsed, input.count)
                let container = try LZMAEncoderCorpus.xz(bytes, input: input, properties: p)
                let compressedURL = directory.appendingPathComponent("\(name)-\(level).xz")
                try container.write(to: compressedURL)
                try ReferenceTool.run(ReferenceTool.xz, ["-t", compressedURL.path], in: directory, log: "\(name)-\(level)-verify")
                let xzStart = ProcessInfo.processInfo.systemUptime
                let oracle = try ReferenceTool.run(ReferenceTool.xz, ["-\(level)", "-T1", "--format=raw", "-c", url.path],
                                                   in: directory, log: "\(name)-\(level)-xz", standardOutput: "\(name)-\(level).raw")
                let xzElapsed = ProcessInfo.processInfo.systemUptime - xzStart
                report(name, level, "xz", oracle.bytes.count, xzElapsed, input.count)
                results[level] = (bytes.count, speed, oracle.bytes.count, Double(input.count) / 1_000_000 / xzElapsed)
                let appleStart = ProcessInfo.processInfo.systemUptime
                let apple = try LZMA2Compressor.encode(input)
                let appleElapsed = ProcessInfo.processInfo.systemUptime - appleStart
                report(name, level, "apple", apple.payload.count, appleElapsed, input.count)
            }
            for level in [6, 9] {
                let r = results[level]!
                TestSupport.report(String(format: "LZMA-BENCH-TARGET\t%@\t%d\tsize-gap=%.3f%%\tspeed/xz=%.3f", name, level,
                                          100 * (Double(r.bytes) / Double(r.xzBytes) - 1), r.speed / r.xzSpeed))
            }
            TestSupport.report(String(format: "LZMA-BENCH-TARGET\t%@\tlevel1/level6=%.3f", name, results[1]!.speed / results[6]!.speed))
        }
        #endif
    }
    private func report(_ name: String, _ level: Int, _ encoder: String, _ count: Int, _ seconds: Double, _ input: Int) {
        TestSupport.report(String(format: "LZMA-BENCH\t%@\t%d\t%@\t%d\t%.3f\t%.6f", name, level, encoder,
                                  count, Double(input) / 1_000_000 / seconds, seconds))
    }
    private func binaryCorpus() throws -> Data {
        let manager = FileManager.default
        var paths = ["/usr/lib/dyld"]
        let root = "/System/Library/Frameworks"
        // bundle の主実行 file は shared cache に移った機械では存在しないため、実在する file だけを選ぶ。
        for bundle in try manager.contentsOfDirectory(atPath: root).sorted() where bundle.hasSuffix(".framework") {
            let stem = String(bundle.dropLast(".framework".count))
            paths.append("\(root)/\(bundle)/Versions/A/\(stem)")
        }
        var result = Data()
        for path in paths where manager.isReadableFile(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard data.count >= 4 else { continue }
            let magic = Array(data.prefix(4))
            guard magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE]
                    || magic == [0xFE, 0xED, 0xFA, 0xCF] else { continue }
            let n = min(data.count, (32 << 20) - result.count)
            result.append(data.prefix(n))
            TestSupport.report("LZMA-BENCH-SOURCE\t\(path)\t\(n)")
            if result.count == 32 << 20 { break }
        }
        guard !result.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return result
    }
}
