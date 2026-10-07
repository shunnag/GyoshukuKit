import Foundation
import XCTest
@testable import GyoshukuKit

final class PPMdWriterOptionsTests: XCTestCase {
    func testOptionsValidateBeforeOutputCreationAndPendingBounds() throws {
        let root = try TestSupport.directory("ppmd-writer-options")
        XCTAssertEqual(WriterOptions().ppmdLevel, 6)
        XCTAssertNil(WriterOptions().ppmdOrder); XCTAssertNil(WriterOptions().ppmdMemoryMiB)
        let orderOnly = WriterOptions(ppmdOrder: 7), memoryOnly = WriterOptions(ppmdMemoryMiB: 3)
        XCTAssertEqual(try orderOnly.ppmd8Properties().order, 7)
        XCTAssertEqual(try orderOnly.ppmd7Properties().memorySize, 16 << 20)
        XCTAssertEqual(try memoryOnly.ppmd8Properties().order, 8)
        XCTAssertEqual(try memoryOnly.ppmd7Properties().order, 6)
        XCTAssertEqual(try memoryOnly.ppmd8Properties().memorySize, 3 << 20)
        for format in [ArchiveFormat.zip, .sevenZip] {
            let upperOrder = format == .zip ? 16 : 32, upperMemory = format == .zip ? 256 : 1024
            for (level, order, memory, field) in [(0, 6, 1, "ppmdLevel"), (10, 6, 1, "ppmdLevel"),
                (6, Int.min, 1, "ppmdOrder"), (6, upperOrder + 1, 1, "ppmdOrder"),
                (6, 6, 0, "ppmdMemoryMiB"), (6, 6, upperMemory + 1, "ppmdMemoryMiB"),
                (6, 6, Int.max, "ppmdMemoryMiB")] {
                let url = root.appendingPathComponent(UUID().uuidString)
                let options = WriterOptions(compressionMethod: .ppmd, sevenZipMethod: .ppmd,
                    ppmdLevel: level, ppmdOrder: order, ppmdMemoryMiB: memory)
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: options)) {
                    XCTAssertEqual($0 as? WriterError, .invalidOption(field))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            for order in [2, upperOrder] {
                for memory in [1, upperMemory] {
                    let options = WriterOptions(compressionMethod: .ppmd, sevenZipMethod: .ppmd, ppmdOrder: order, ppmdMemoryMiB: memory)
                    XCTAssertNoThrow(try options.validate(for: format))
                    let size = format == .zip ? try options.ppmd8Properties().memorySize : try options.ppmd7Properties().memorySize
                    XCTAssertEqual(size, memory << 20)
                }
            }
            for threads in [1, 4, 64] {
                let options = WriterOptions(compressionMethod: .ppmd, sevenZipMethod: .ppmd, memoryLimit: 1, compressionThreads: threads)
                XCTAssertEqual(options.maximumPendingInputBytes(for: format), format == .zip
                    ? EntryCompressionConfiguration(options: options).maximumPendingInputBytes
                    : EntryCompressionConfiguration(options: options, method: .ppmd).maximumPendingInputBytes)
                XCTAssertNoThrow(try options.validate(for: format))
            }
        }
        let solid = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(), ppmdLevel: 9)
        XCTAssertEqual(solid.maximumPendingInputBytes(for: .sevenZip), UInt64(EntryCompressionConfiguration(options: solid, method: .ppmd).threads) * (384 << 20))
        let explicit = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(blockSize: 123), ppmdMemoryMiB: 1)
        XCTAssertEqual(explicit.maximumPendingInputBytes(for: .sevenZip), UInt64(EntryCompressionConfiguration(options: explicit, method: .ppmd).threads) * 123)
    }
}
