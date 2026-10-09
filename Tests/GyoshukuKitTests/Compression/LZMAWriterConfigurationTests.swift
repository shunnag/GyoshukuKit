import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMAWriterConfigurationTests: XCTestCase {
    func testFinderBufferMemoryAndSingleStreamEnablement() throws {
        for threads in [1, 2, 16, 36] {
            let options = WriterOptions(lzmaLevel: 6, memoryLimit: 1 << 30, compressionThreads: threads)
            let sequential = try LZMAWriterConfiguration(options: options, raw: true)
            let parallel = try LZMAWriterConfiguration(options: options, raw: true, parallelFinder: true)
            XCTAssertEqual(parallel.finderThreads, threads == 1 ? 1 : 2)
            let extra = threads == 1 ? 0 : LZMAMatchFinderPipeline.memorySize
            XCTAssertEqual(parallel.encoderMemory, sequential.encoderMemory + extra)
            XCTAssertEqual(parallel.memoryPerThread, sequential.memoryPerThread + UInt64(extra))
            XCTAssertEqual(try LZMAWriterConfiguration.singleStream(options: options).finderThreads, parallel.finderThreads)
            XCTAssertEqual(try LZMAWriterConfiguration(options: options, parallelFinder: true).finderThreads, 1)
            XCTAssertEqual(try LZMAWriterConfiguration.singleStream(options: options, lzip: true).finderThreads, 1)
            var tight = options
            tight.memoryLimit = sequential.memoryPerThread
            XCTAssertEqual(try LZMAWriterConfiguration(options: tight, raw: true, parallelFinder: true).finderThreads, 1)
        }
    }

    func testRawSlackMemoryAndDerivedPendingBounds() throws {
        // 64-bit 通常 preset の raw予約を固定し、slack と range最大16 MiBの計上を検査する。
        let rawMemory = [19_342_481, 25_240_721, 33_105_041, 48_833_681, 65_610_901,
                         113_845_397, 113_845_397, 206_120_085, 390_669_461, 692_659_349]
        let lzipThreads = [60, 54, 48, 39, 32, 19, 19, 10, 5, 2]
        let lzipPendingMiB = [960, 864, 768, 624, 512, 456, 456, 480, 480, 384]
        for level in 0...9 {
            let options = WriterOptions(lzmaLevel: level, memoryLimit: 3 << 30, compressionThreads: 64)
            let raw = try LZMAWriterConfiguration(options: options, raw: true, physicalMemory: 8 << 30)
            XCTAssertEqual(raw.encoderMemory, rawMemory[level], "level \(level)")
            XCTAssertEqual(raw.memoryPerThread, UInt64(rawMemory[level] + 524288), "level \(level)")
            let lzip = try LZMAWriterConfiguration(options: options, raw: true, lzip: true, physicalMemory: 8 << 30)
            XCTAssertEqual(lzip.threads, lzipThreads[level], "level \(level)")
            XCTAssertEqual(options.maximumPendingInputBytes(for: .tarLzip, physicalMemory: 8 << 30),
                           UInt64(lzipPendingMiB[level]) << 20, "level \(level)")
            var insufficient = options
            insufficient.memoryLimit = raw.memoryPerThread - 1
            XCTAssertThrowsError(try LZMAWriterConfiguration(options: insufficient, raw: true, physicalMemory: 8 << 30))
        }
        // 新予約の三枠に1 byte足りない境界では、ZIP / 7z の項目窓は二枠に減る。
        let options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma, lzmaLevel: 6,
                                    memoryLimit: 399_732_158, compressionThreads: 64)
        for format in [ArchiveFormat.zip, .sevenZip] {
            XCTAssertEqual(options.maximumPendingInputBytes(for: format, physicalMemory: 8 << 30), 48 << 20)
        }
    }

    func testPieceSizesMemoryBudgetAndPendingInputBounds() throws {
        // 固定予算の値は別表に保持し、実装の解決結果から期待値を作らない。
        // 3 GiB / 物理8 GiB。探索buffer縮小後はlevel 2 / 4 / 5 / 6が一枠増える。
        let resolvedThreads = [64, 64, 63, 48, 39, 25, 25, 14, 5, 2]
        let zipMiB = [1040, 1040, 1024, 784, 640, 416, 416, 240, 576, 576]
        let sevenMiB = [1024, 1024, 1008, 768, 624, 400, 400, 224, 480, 384]
        for level in 0...9 {
            let options = WriterOptions(compressionMethod: .xz, lzmaLevel: level, memoryLimit: 3 << 30, compressionThreads: 64)
            let configuration = try LZMAWriterConfiguration(options: options, physicalMemory: 8 << 30)
            let piece = level == 9 ? 192 << 20 : level == 8 ? 96 << 20 : 16 << 20
            XCTAssertEqual(configuration.pieceSize, piece)
            XCTAssertEqual(configuration.threads, resolvedThreads[level], "level \(level)")
            XCTAssertLessThanOrEqual(UInt64(configuration.threads) * configuration.memoryPerThread, configuration.memoryBudget)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip, physicalMemory: 8 << 30), UInt64(zipMiB[level]) << 20, "level \(level)")
            XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 8 << 30), UInt64(sevenMiB[level]) << 20, "level \(level)")
        }
        let options = WriterOptions(lzmaLevel: 9, memoryLimit: .max, compressionThreads: 64)
        let configuration = try LZMAWriterConfiguration(options: options, physicalMemory: 4 << 30)
        XCTAssertEqual(configuration.memoryBudget, 2 << 30)
        XCTAssertEqual(configuration.threads, 1)
        let zipRaw = WriterOptions(compressionMethod: .lzma, memoryLimit: 4 << 30, compressionThreads: 12)
        XCTAssertEqual(zipRaw.maximumPendingInputBytes(for: .zip, physicalMemory: 16 << 30), 192 << 20)
        let sevenRaw = WriterOptions(sevenZipMethod: .lzma, memoryLimit: 4 << 30, compressionThreads: 12)
        XCTAssertEqual(sevenRaw.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 192 << 20)
        XCTAssertNil(WriterOptions().lzmaLevel)
        XCTAssertFalse(WriterOptions().lzmaExtreme)
        for threads in [Int.min, 0, 1025, Int.max] {
            let options = WriterOptions(compressionMethod: .xz, compressionThreads: threads)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip), UInt64(max(1, min(WriterOptions.compressionThreadsRange.upperBound, threads)) + 1) * UInt64(16 << 20))
        }
    }

    func testInvalidLevelAndInsufficientMemoryFailBeforeCreatingOutput() throws {
        let directory = try TestSupport.directory("lzma-writer-options")
        for format in [ArchiveFormat.tarXZ, .sevenZip, .zip] {
            for level in [Int.min, -1, 10, Int.max] {
                let url = directory.appendingPathComponent("\(format)-\(level)")
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: .init(lzmaLevel: level))) {
                    XCTAssertEqual($0 as? WriterError, .invalidOption("lzmaLevel"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            let url = directory.appendingPathComponent("\(format)-memory")
            let options = WriterOptions(compressionMethod: .xz, lzmaLevel: 9, memoryLimit: 768 << 20, compressionThreads: 64)
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: options)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        for raw in [false, true] {
            XCTAssertThrowsError(try LZMAWriterConfiguration(options: .init(lzmaLevel: 9, memoryLimit: 32 << 20), raw: raw)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
        }
        for format in [ArchiveFormat.zip, .sevenZip] {
            let url = directory.appendingPathComponent("\(format)-raw-memory")
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format,
                options: .init(compressionMethod: .lzma, sevenZipMethod: .lzma, memoryLimit: 32 << 20))) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        // Apple の既定経路は自前 encoder の予算で変えない。
        XCTAssertNoThrow(try WriterOptions(compressionMethod: .xz, memoryLimit: 1).validate(for: .tarXZ))
        XCTAssertNoThrow(try WriterOptions(compressionMethod: .stored, lzmaLevel: 9, memoryLimit: 1).validate(for: .zip))
    }
}
