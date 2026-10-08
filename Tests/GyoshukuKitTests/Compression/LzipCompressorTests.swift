import Foundation
import XCTest
@testable import GyoshukuKit

final class LzipCompressorTests: XCTestCase {
    func testRawMemoryBudgetLimitsThreadsAndKeepsDictionary() throws {
        for level in 0...9 {
            let options = WriterOptions(lzmaLevel: level, memoryLimit: 3 << 30, compressionThreads: 64)
            let configuration = try LZMAWriterConfiguration(options: options, raw: true, lzip: true, physicalMemory: 8 << 30)
            let properties = LZMAEncoderProperties.preset(level)
            XCTAssertEqual(configuration.properties, properties)
            XCTAssertEqual(configuration.pieceSize, max(16 << 20, 3 * properties.dictSize))
            XCTAssertEqual(configuration.memoryPerThread, UInt64(configuration.encoderMemory + 2 * configuration.pieceSize))
            XCTAssertEqual(configuration.threads, min(options.compressionThreads!, Int(configuration.memoryBudget / configuration.memoryPerThread)))
            XCTAssertLessThanOrEqual(UInt64(configuration.threads) * configuration.memoryPerThread, configuration.memoryBudget)
            var limited = options
            limited.memoryLimit = configuration.memoryPerThread * 2
            let two = try LZMAWriterConfiguration(options: limited, raw: true, lzip: true, physicalMemory: 8 << 30)
            XCTAssertEqual(two.threads, 2)
            XCTAssertEqual(two.properties?.dictSize, properties.dictSize)
            limited.memoryLimit = configuration.memoryPerThread - 1
            XCTAssertThrowsError(try LZMAWriterConfiguration(options: limited, raw: true, lzip: true, physicalMemory: 8 << 30)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
        }
        XCTAssertEqual(try LZMAWriterConfiguration.singleStream(options: .init(lzmaExtreme: true), lzip: true).properties,
                       .preset(6, extreme: true))
        for threads in [Int.min, 0, WriterOptions.compressionThreadsRange.upperBound + 1, Int.max] {
            XCTAssertGreaterThan(WriterOptions(compressionThreads: threads).maximumPendingInputBytes(for: .tarLzip), 0)
        }
    }

    func testDictionaryCodeIncludesFractionAndRejectsOutOfRange() throws {
        XCTAssertEqual(try LzipFraming.dictionaryCode(4096), 12)
        XCTAssertEqual(try LzipFraming.dictionaryCode(1 << 18), 18)
        XCTAssertEqual(try LzipFraming.dictionaryCode(3 << 20), 22 | (4 << 5))
        XCTAssertEqual(try LzipFraming.dictionaryCode(1 << 29), 29)
        for invalid in [0, 3840, 4097, (1 << 29) + 1] {
            XCTAssertThrowsError(try LzipFraming.dictionaryCode(invalid))
        }
    }

    func testParallelMembersAreByteIdenticalAndInputIsBounded() throws {
        let directory = try TestSupport.directory("lzip-parallel-members")
        // 16 MiB を越える入力に、空 write と非ゼロstartIndexのsliceを挟む。
        var input = Data(repeating: 0x41, count: (16 << 20) + 129)
        input.replaceSubrange(0..<65_536, with: TestCorpus.random(65_536))
        var reference: Data?
        for threads in [1, 4] {
            let options = WriterOptions(lzmaLevel: 0, compressionThreads: threads)
            let compressor = try ParallelLzipCompressor(options: options)
            var output = Data()
            for offset in stride(from: input.startIndex, to: input.endIndex, by: IOChunk.size + 7) {
                try compressor.write(Data(), finish: false) { output.append($0) }
                try compressor.write(input[offset..<min(input.endIndex, offset + IOChunk.size + 7)], finish: false) { output.append($0) }
                XCTAssertLessThanOrEqual(compressor.pendingInputBytes, options.maximumPendingInputBytes(for: .tarLzip))
            }
            try compressor.write(Data(), finish: true) { output.append($0) }
            XCTAssertEqual(compressor.pendingInputBytes, 0)
            XCTAssertEqual(try SingleStreamTestSupport.lzipMemberRanges(output).count, 2)
            if let reference { XCTAssertEqual(output, reference) } else { reference = output }
            let url = directory.appendingPathComponent("threads-\(threads).lz")
            try output.write(to: url)
            try SingleStreamTestSupport.assertCLI(url, format: .lzip, input: input, in: directory, label: "threads-\(threads)")
            try StreamEncoderTestSupport.assertKaito(url, equals: input)
        }
    }
}
