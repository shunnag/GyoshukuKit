import Foundation
import XCTest
@testable import GyoshukuKit

final class ZstdWriterConfigurationTests: XCTestCase {
    func testMemoryBudgetReducesThreadsAndRejectsBeforeCreatingOutput() throws {
        XCTAssertEqual(WriterOptions().zstdLevel, 3)
        for level in [1, 3, 19] {
            var options = WriterOptions(zstdLevel: level, compressionThreads: 64)
            let full = try ZstdWriterConfiguration(options: options, physicalMemory: 8 << 30)
            options.memoryLimit = full.memoryPerThread * 2
            let limited = try ZstdWriterConfiguration(options: options, physicalMemory: 8 << 30)
            XCTAssertEqual(limited.threads, 2)
            XCTAssertEqual(limited.properties.windowSize, full.properties.windowSize)
            XCTAssertEqual(limited.chunkSize, level == 19 ? 8 << 20 : 4 << 20)
            let directory = try TestSupport.directory("zstd-memory-refusal-\(level)")
            options.memoryLimit = full.memoryPerThread - 1
            let url = directory.appendingPathComponent("refused.tar.zst")
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .tarZstd, options: options)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        for format in [GyoshukuKit.ArchiveFormat.tarZstd, .zip] {
            for level in [Int.min, 0, 20, Int.max] {
                XCTAssertThrowsError(try WriterOptions(compressionMethod: .zstd, zstdLevel: level).validate(for: format)) {
                    XCTAssertEqual($0 as? WriterError, .invalidOption("zstdLevel"))
                }
            }
            XCTAssertThrowsError(try WriterOptions(compressionMethod: .zstd, memoryLimit: 1).validate(for: format))
        }
    }

    func testFixedChunksAreBoundedAndThreadIndependent() throws {
        let directory = try TestSupport.directory("zstd-fixed-chunks")
        let input = Data(repeating: 0x41, count: (4 << 20) + 129)
        var baseline: Data?
        for threads in [1, 4] {
            let options = WriterOptions(compressionThreads: threads)
            let compressor = try ParallelZstdCompressor(options: options)
            var output = Data()
            for offset in stride(from: 0, to: input.count, by: IOChunk.size + 7) {
                try compressor.write(Data(), finish: false) { output.append($0) }
                try compressor.write(input[offset..<min(input.count, offset + IOChunk.size + 7)], finish: false) { output.append($0) }
                XCTAssertLessThanOrEqual(compressor.pendingInputBytes, options.maximumPendingInputBytes(for: .tarZstd))
            }
            try compressor.write(Data(), finish: true) { output.append($0) }
            XCTAssertEqual(compressor.pendingInputBytes, 0)
            XCTAssertEqual(try ZstdWriterTestSupport.frames(output).map(\.contentSize), [4 << 20, 129])
            if let baseline { XCTAssertEqual(output, baseline) } else { baseline = output }
            let url = directory.appendingPathComponent("threads-\(threads).zst")
            try output.write(to: url)
            try SingleStreamTestSupport.assertCLI(url, format: .zstd, input: input, in: directory, label: "threads-\(threads)")
            try StreamEncoderTestSupport.assertKaito(url, equals: input)
        }
    }
}
