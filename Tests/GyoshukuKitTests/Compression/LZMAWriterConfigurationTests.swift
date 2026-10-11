import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMAWriterConfigurationTests: XCTestCase {
    func testFinderBufferMemoryAndSingleStreamEnablement() throws {
        // 二つの block / offset、stack、管理余裕と pairBuffer 2,192 byte を含む。
        XCTAssertEqual(LZMAMatchFinderPipeline.memorySize, 18_520_216)
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
        let rawMemory = [19_344_681, 25_242_921, 33_107_241, 48_835_881, 65_613_101,
                         113_847_597, 113_847_597, 206_122_285, 390_671_661, 692_661_549]
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
            let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                try LZMAWriterConfiguration(options: options, raw: true, physicalMemory: 8 << 30)
            }
            insufficient.memoryLimit = legacy.memoryPerThread - 1
            XCTAssertThrowsError(try LZMAWriterConfiguration(options: insufficient, raw: true, physicalMemory: 8 << 30))
        }
        // この固定予算では、ZIP / 7z の入力上界は予約追加後も48 MiBを保つ。
        let options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma, lzmaLevel: 6,
                                    memoryLimit: 399_732_158, compressionThreads: 64)
        for format in [ArchiveFormat.zip, .sevenZip] {
            XCTAssertEqual(options.maximumPendingInputBytes(for: format, physicalMemory: 8 << 30), 48 << 20)
        }
        // 三つの通常/専用状態とfinder一組が入る旧境界から、新境界は8,792 byte増える。
        for (budget, pending) in [(UInt64(418_250_183), UInt64(48 << 20)), (418_258_975, 64 << 20)] {
            var boundary = options
            boundary.memoryLimit = budget
            for format in [ArchiveFormat.zip, .sevenZip] {
                XCTAssertEqual(boundary.maximumPendingInputBytes(for: format, physicalMemory: 8 << 30), pending,
                               "\(format) budget \(budget)")
            }
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
