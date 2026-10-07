import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMAWriterConfigurationTests: XCTestCase {
    func testPieceSizesMemoryBudgetAndPendingInputBounds() throws {
        for level in 0...9 {
            let options = WriterOptions(compressionMethod: .xz, lzmaLevel: level, memoryLimit: 3 << 30, compressionThreads: 64)
            let configuration = try LZMAWriterConfiguration(options: options, physicalMemory: 8 << 30)
            let piece = level == 9 ? 192 << 20 : level == 8 ? 96 << 20 : 16 << 20
            XCTAssertEqual(configuration.pieceSize, piece)
            XCTAssertEqual(configuration.threads, min(64, Int((3 << 30) / configuration.memoryPerThread)))
            XCTAssertLessThanOrEqual(UInt64(configuration.threads) * configuration.memoryPerThread, configuration.memoryBudget)
            // 固定予算の値は別表に保持し、実装の解決結果から期待値を作らない。
            let zipMiB = [1040, 1040, 1008, 784, 624, 400, 400, 240, 576, 576]
            let sevenMiB = [1024, 1024, 992, 768, 608, 384, 384, 224, 480, 384]
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip, physicalMemory: 8 << 30), UInt64(zipMiB[level]) << 20)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 8 << 30), UInt64(sevenMiB[level]) << 20)
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
        for threads in [Int.min, 0, 65, Int.max] {
            let options = WriterOptions(compressionMethod: .xz, compressionThreads: threads)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip), UInt64(max(1, min(64, threads)) + 1) * UInt64(16 << 20))
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
