// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation
import XCTest
@testable import GyoshukuKit

/// Opt-in release measurement. External tools are mandatory under Tests/README.md.
final class ZstdEncoderBenchmarkTests: XCTestCase {
    func testSingleThreadBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_ZSTD_BENCHMARK")
        #if DEBUG
        XCTFail("Run ZstdEncoderBenchmarkTests with -c release")
        return
        #else
        let directory = try TestSupport.directory("zstd-encoder-benchmark")
        let tool = "/opt/homebrew/bin/zstd"
        let text = LZMAEncoderCorpus.text(size: 4 << 20)
        let binary = try Self.binaryCorpus()
        TestSupport.report("ZSTD-BENCH\tcorpus\tlevel\tencoder\tbytes\tMB/s\tseconds")
        for (name, input) in [("text",text), ("binary",binary)] {
            let plain = directory.appendingPathComponent(name + ".bin")
            try input.write(to: plain)
            TestSupport.report("ZSTD-BENCH-CORPUS\t\(name)\t\(input.count)")
            let levels = ProcessInfo.processInfo.environment["GYOSHUKU_ZSTD_ALL_LEVELS"] == "1" ? Array(1...19) : [1,3,9,19]
            for level in levels {
                var fastest = Double.infinity, encoded = Data()
                // Repeat until >= 0.3 seconds, at least five runs, taking the best end-to-end encoder time.
                var measured = 0.0, runs = 0
                repeat {
                    let start = ProcessInfo.processInfo.systemUptime
                    encoded = try ZstdFrameEncoder.encode(input, level: level)
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    measured += seconds; runs += 1; fastest = min(fastest, seconds)
                } while runs < 5 || (measured < 0.3 && runs < 20)
                let swiftSpeed = Double(input.count) / 1_000_000 / fastest
                report(name, level, "swift", encoded.count, fastest, input.count)
                let url = directory.appendingPathComponent("\(name)-\(level).zst")
                try encoded.write(to: url)
                try ReferenceTool.run(tool, ["-t",url.path], in: directory, log: "\(name)-\(level)-verify")
                try StreamEncoderTestSupport.assertKaito(url, equals: input)
                // Size from the normal single-thread CLI with default checksum enabled.
                let oracle = try ReferenceTool.run(tool, ["-\(level)","-T1","-c",plain.path], in: directory,
                                                   log: "\(name)-\(level)-reference", standardOutput: "\(name)-\(level)-reference.zst")
                // The tool's timed loop excludes process launch / file I/O. Use it for honest throughput.
                let timed = try ReferenceTool.run(tool, ["-b\(level)","-e\(level)","-i1","-T1",plain.path],
                                                  in: directory, log: "\(name)-\(level)-timing")
                let referenceSpeed = try speed(timed.utf8Text)
                TestSupport.report(String(format: "ZSTD-BENCH\t%@\t%d\tzstd\t%d\t%.3f\t%.6f", name, level,
                                          oracle.bytes.count, referenceSpeed, Double(input.count) / 1_000_000 / referenceSpeed))
                let gap = 100 * (Double(encoded.count) / Double(oracle.bytes.count) - 1)
                let speedRatio = swiftSpeed / referenceSpeed
                TestSupport.report(String(format: "ZSTD-BENCH-TARGET\t%@\t%d\tsize-gap=%.3f%%\tspeed/zstd=%.3f", name, level, gap, speedRatio))
                let sizeMiss = level == 3 ? gap > 10 : level == 19 ? gap > 8 : false
                let speedMiss = level == 1 ? speedRatio < 0.50 : level == 3 ? speedRatio < 0.50 : false
                if sizeMiss || speedMiss {
                    TestSupport.report("ZSTD-BENCH-MISS\t\(name)\t\(level)\tsize=\(sizeMiss)\tspeed=\(speedMiss)")
                }
                // Stage timings are collected separately, outside the uninstrumented speed measurement.
                let profile = try ZstdFrameEncoder(level: level, contentSize: UInt64(input.count), collectProfile: true)
                try profile.write(input, finish: true) { _ in }
                TestSupport.report(profile.profile.report(corpus: name, level: level))
            }
        }
        #endif
    }
    private func report(_ name: String, _ level: Int, _ encoder: String, _ bytes: Int, _ seconds: Double, _ count: Int) {
        TestSupport.report(String(format: "ZSTD-BENCH\t%@\t%d\t%@\t%d\t%.3f\t%.6f", name, level, encoder,
                                  bytes, Double(count) / 1_000_000 / seconds, seconds))
    }
    private func speed(_ output: String) throws -> Double {
        let expression = try NSRegularExpression(pattern: #"\(x[0-9.]+\),\s*([0-9.]+)\s+MB/s"#)
        let matches = expression.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: output),
              let speed = Double(output[range]) else {
            XCTFail("Could not read zstd benchmark speed: \(output)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return speed
    }
    static func binaryCorpus() throws -> Data {
        let manager = FileManager.default
        var paths = ["/usr/lib/dyld"]
        let root = "/System/Library/Frameworks"
        for bundle in try manager.contentsOfDirectory(atPath: root).sorted() where bundle.hasSuffix(".framework") {
            let stem = String(bundle.dropLast(".framework".count))
            paths.append("\(root)/\(bundle)/Versions/A/\(stem)")
        }
        var result = Data()
        for path in paths where manager.isReadableFile(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard data.count >= 4 else { continue }
            let magic = Array(data.prefix(4))
            guard magic == [0xCF,0xFA,0xED,0xFE] || magic == [0xCA,0xFE,0xBA,0xBE] || magic == [0xFE,0xED,0xFA,0xCF] else { continue }
            let n = min(data.count, (32 << 20) - result.count)
            result.append(data.prefix(n)); TestSupport.report("ZSTD-BENCH-SOURCE\t\(path)\t\(n)")
            if result.count == 32 << 20 { break }
        }
        guard !result.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return result
    }
}
