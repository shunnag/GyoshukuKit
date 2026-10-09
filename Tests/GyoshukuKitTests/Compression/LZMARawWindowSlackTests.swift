import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMARawWindowSlackTests: XCTestCase {
    private func encode(_ input: Data, properties: LZMAEncoderProperties, legacy: Bool,
                        threads: Int, width: Int) throws -> Data {
        try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(legacy) {
            let encoder = try LZMAEncoder(properties: properties, expectedSize: UInt64(input.count), finderThreads: threads)
            var output = Data()
            for start in stride(from: 0, to: input.count, by: width) {
                output.append(try encoder.push(input.subdata(in: start..<min(input.count, start + width))))
            }
            output.append(try encoder.finish())
            return output
        }
    }

    // 両windowのcompactを越え、HC4 / BT4とfinder並列でも旧slackのbyteを保つ。
    func testLegacyAndExpandedSlackHaveIdenticalBytesAcrossCompaction() throws {
        for level in [0, 3, 6] {
            for dictionary in [1 << 20, 8 << 20] {
                var properties = LZMAEncoderProperties.preset(level)
                properties.dictSize = dictionary
                let size = 2 * (dictionary + LZMAEncodingEngine.windowSlack(dictionary: dictionary)
                    + LZMAEncodingEngine.lookahead + 65536) + 777
                let input = LZMAEncoderCorpus.mixed(size: size)
                let expected = try encode(input, properties: properties, legacy: true, threads: 1, width: 65537)
                for threads in [1, 2] {
                    let actual = try encode(input, properties: properties, legacy: false, threads: threads, width: 262144)
                    XCTAssertEqual(actual, expected, "level=\(level), dict=\(dictionary), finder=\(threads)")
                }
            }
        }
    }

    func testLegacyMemoryBudgetsRemainAcceptedForAllPresets() throws {
        for level in 0...9 {
            for lzip in [false, true] {
                var options = WriterOptions(lzmaLevel: level, memoryLimit: 3 << 30, compressionThreads: 4)
                let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                    try LZMAWriterConfiguration(options: options, raw: true, lzip: lzip, physicalMemory: 8 << 30)
                }
                let expanded = try LZMAWriterConfiguration(options: options, raw: true, lzip: lzip, physicalMemory: 8 << 30)
                for budget in [legacy.memoryPerThread, expanded.memoryPerThread - 1] {
                    options.memoryLimit = budget
                    let configuration = try LZMAWriterConfiguration(options: options, raw: true, lzip: lzip,
                        parallelFinder: !lzip, physicalMemory: 8 << 30)
                    XCTAssertTrue(configuration.legacyRawWindowSlack)
                    XCTAssertLessThanOrEqual(configuration.memoryPerThread, budget)
                }
                options.memoryLimit = legacy.memoryPerThread - 1
                XCTAssertThrowsError(try LZMAWriterConfiguration(options: options, raw: true, lzip: lzip,
                    physicalMemory: 8 << 30)) { XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit")) }
            }
        }
    }

    func testTightRawBudgetCreatesZIPSevenZipAndSingleStreamsWithIdenticalBytes() throws {
        let root = try TestSupport.directory("review-lzma-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = LZMAEncoderCorpus.text(size: (1 << 20) + 7)
        for format: ArchiveFormat in [.zip, .sevenZip, .tarLZMA, .tarLzip] {
            let lzip = format == .tarLzip
            var options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma, lzmaLevel: 6,
                memoryLimit: 1 << 30, useCompressionHeuristic: false, compressionThreads: 4)
            let baseline = root.appendingPathComponent(UUID().uuidString)
            let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                let writer = try ArchiveWriter.create(url: baseline, format: format, options: options)
                try writer.add(data: input, as: "input", modificationDate: TestSupport.date)
                try writer.finish()
                return try LZMAWriterConfiguration(options: options, raw: true, lzip: lzip)
            }
            options.memoryLimit = legacy.memoryPerThread
            let output = root.appendingPathComponent(UUID().uuidString)
            let writer = try ArchiveWriter.create(url: output, format: format, options: options)
            try writer.add(data: input, as: "input", modificationDate: TestSupport.date)
            try writer.finish()
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: baseline), "\(format)")
        }
        let source = root.appendingPathComponent("source")
        try input.write(to: source)
        for format: SingleStreamFormat in [.lzma, .lzip] {
            var options = WriterOptions(lzmaLevel: 6, memoryLimit: 1 << 30, compressionThreads: 4)
            let baseline = root.appendingPathComponent(UUID().uuidString)
            let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                try SingleStreamCompressor.compress(file: source, to: baseline, format: format, options: options)
                return try LZMAWriterConfiguration.singleStream(options: options, lzip: format == .lzip)
            }
            options.memoryLimit = legacy.memoryPerThread
            let output = root.appendingPathComponent(UUID().uuidString)
            try SingleStreamCompressor.compress(file: source, to: output, format: format, options: options)
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: baseline), "\(format)")
        }
    }
}
