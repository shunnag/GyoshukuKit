import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMAMultithreadedWriterTests: XCTestCase {
    func testRawLZMAWritersKeepIdentityAtOneTwoSixteenThirtySixThreads() throws {
        let root = try TestSupport.directory("lzma-mt-writer-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = LZMAEncoderCorpus.text(size: 131073)
        let source = root.appendingPathComponent("source")
        try payload.write(to: source)
        let configurations: [(ArchiveFormat, SevenZipSolidMode)] = [
            (.zip, .off), (.sevenZip, .off), (.sevenZip, .on(blockSize: 65536, filesPerBlock: 1)), (.tarLZMA, .off)
        ]
        for level in 0...9 {
            for extreme in [false, true] {
                for (index, configuration) in configurations.enumerated() {
                    var expected: Data?
                    for threads in [1, 2, 16, 36] {
                        // 読み取りでatimeが変わるため、ZIPの時刻メタデータも毎回固定する。
                        try AdditionProgressTestSupport.timestamp(source)
                        let options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma,
                            sevenZipSolid: configuration.1, lzmaLevel: level, lzmaExtreme: extreme, useCompressionHeuristic: false, compressionThreads: threads)
                        let url = root.appendingPathComponent("\(level)-\(extreme)-\(index)-\(threads)")
                        let before = LZMAMatchFinderPipeline.testingWorkerCounts
                        try EntryCompressionConfiguration.$testingInputLimit.withValue(65536) {
                            let writer = try ArchiveWriter.create(url: url, format: configuration.0, options: options)
                            // 通常窓が残るlong-poleと、fileからのZIP streamed経路を通る。
                            try writer.add(data: Data(payload.prefix(32768)), as: "medium", modificationDate: TestSupport.date)
                            try writer.add([.init(path: "large", source: .contents(of: source))], events: nil)
                            try writer.finish()
                        }
                        let bytes = try Data(contentsOf: url)
                        if let expected { XCTAssertEqual(bytes, expected, "format=\(configuration.0), solid=\(configuration.1), threads=\(threads)") }
                        else { expected = bytes }
                        let after = LZMAMatchFinderPipeline.testingWorkerCounts
                        XCTAssertEqual(after.live, before.live)
                        if threads == 1 { XCTAssertEqual(after.starts, before.starts) }
                        else { XCTAssertGreaterThan(after.starts, before.starts, "\(configuration.0), threads=\(threads)") }
                    }
                }
                var alone: Data?
                for threads in [1, 2, 16, 36] {
                    try AdditionProgressTestSupport.timestamp(source)
                    let url = root.appendingPathComponent("alone-\(level)-\(extreme)-\(threads).lzma")
                    try SingleStreamCompressor.compress(file: source, to: url, format: .lzma,
                        options: WriterOptions(lzmaLevel: level, lzmaExtreme: extreme, compressionThreads: threads))
                    let bytes = try Data(contentsOf: url)
                    if let alone { XCTAssertEqual(bytes, alone) } else { alone = bytes }
                }
            }
        }
    }

    func testNormalItemWindowsKeepFinderSequential() throws {
        let root = try TestSupport.directory("lzma-mt-normal-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = LZMAMatchFinderPipeline.testingWorkerCounts
        for format: ArchiveFormat in [.zip, .sevenZip] {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(format)"), format: format,
                options: WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma, lzmaLevel: 0,
                    useCompressionHeuristic: false, compressionThreads: 16))
            for i in 0..<8 { try writer.add(data: TestCorpus.random(8192), as: "file-\(i)", modificationDate: TestSupport.date) }
            try writer.finish()
        }
        XCTAssertEqual(LZMAMatchFinderPipeline.testingWorkerCounts.starts, before.starts)
    }

    func testReadAndSinkErrorsJoinFinderBeforeReturning() throws {
        let options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma, compressionThreads: 2)
        let payload = LZMAEncoderCorpus.text(size: 3 * IOChunk.size)
        for sevenZip in [false, true] {
            for readFailure in [false, true] {
                let before = LZMAMatchFinderPipeline.testingWorkerCounts
                var offset = 0
                func read(_ count: Int) throws -> Data {
                    if readFailure && offset >= IOChunk.size { throw WriterError.compression(-71) }
                    let end = min(payload.count, offset + count)
                    defer { offset = end }
                    return payload.subdata(in: offset..<end)
                }
                func write(_ data: Data) throws {
                    if !readFailure && offset >= IOChunk.size { throw WriterError.compression(-72) }
                }
                XCTAssertThrowsError(try {
                    if sevenZip {
                        _ = try SevenZipFolderEncoder.encode(size: UInt64(payload.count), options: options,
                            aes: nil, read: read, write: write)
                    } else {
                        _ = try ZipEntryCompressor(options: options).compress(name: "source", size: UInt64(payload.count),
                            method: .lzma, read: read, emit: write)
                    }
                }()) { XCTAssertEqual($0 as? WriterError, .compression(readFailure ? -71 : -72)) }
                let after = LZMAMatchFinderPipeline.testingWorkerCounts
                XCTAssertGreaterThan(after.starts, before.starts)
                XCTAssertEqual(after.live, before.live)
            }
        }
    }
}
