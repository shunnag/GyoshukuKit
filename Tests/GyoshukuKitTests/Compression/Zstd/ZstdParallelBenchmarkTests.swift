import Foundation
import XCTest
@testable import GyoshukuKit

/// 公開 writer の file I/O・frame 組立・checksum・finish を含む opt-in 計測。
final class ZstdParallelBenchmarkTests: XCTestCase {
    func testWritersAtOneFourEightTwelveThreads() throws {
        try OptInGate.flag("GYOSHUKU_ZSTD_PARALLEL_BENCHMARK")
        #if DEBUG
        XCTFail("Run ZstdParallelBenchmarkTests with -c release")
        #else
        let directory = try TestSupport.directory("zstd-parallel-benchmark")
        let seed = LZMAEncoderCorpus.text(size: 4 << 20) + (try ZstdEncoderBenchmarkTests.binaryCorpus())
        var input = Data(); input.reserveCapacity(256 << 20)
        while input.count < 256 << 20 { input.append(seed.prefix((256 << 20) - input.count)) }
        let source = directory.appendingPathComponent("input.bin")
        try input.write(to: source)
        for tar in [false, true] {
            var baseline: Data?
            for threads in [1, 4, 8, 12] {
                let url = directory.appendingPathComponent("threads-\(threads)." + (tar ? "tar.zst" : "zst"))
                var fastest = Double.infinity
                for run in 0..<5 {
                    if run > 0 { try FileManager.default.removeItem(at: url) }
                    let start = ProcessInfo.processInfo.systemUptime
                    let options = WriterOptions(zstdLevel: 3, compressionThreads: threads)
                    if tar {
                        let writer = try ArchiveWriter.create(url: url, format: .tarZstd, options: options)
                        try writer.add(contentsOf: source, as: "input.bin")
                        try writer.finish()
                    } else {
                        try SingleStreamCompressor.compress(file: source, to: url, format: .zstd, options: options)
                    }
                    fastest = min(fastest, ProcessInfo.processInfo.systemUptime - start)
                }
                let output = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(output, baseline) } else { baseline = output }
                try ReferenceTool.run("/opt/homebrew/bin/zstd", ["-t", url.path], in: directory, log: "verify-\(tar)-\(threads)")
                TestSupport.report(String(format: "ZSTD-PARALLEL\t%@\t%d\t%d\t%d\t%.3f\t%.6f", tar ? "tar.zst" : ".zst", threads, input.count, output.count, Double(input.count) / 1e6 / fastest, fastest))
            }
        }
        #endif
    }
}
