import Foundation
import XCTest
@testable import GyoshukuKit

final class EntryCompressionConfigurationTests: XCTestCase {
    func testLZMAFinderReservesCoresAndMemoryWithinRequestedBudget() throws {
        for requested in [1, 2, 3, 16, 36] {
            let options = WriterOptions(compressionMethod: .lzma, sevenZipMethod: .lzma,
                lzmaLevel: 0, memoryLimit: 4 << 30, compressionThreads: requested)
            let zip = EntryCompressionConfiguration(options: options, physicalMemory: 16 << 30)
            XCTAssertEqual(zip.longPoleThreads, requested == 1 ? 0 : 1)
            XCTAssertLessThanOrEqual(zip.threads + zip.longPoleThreads, requested)
            let sevenZip = EntryCompressionConfiguration(options: options, method: .lzma, physicalMemory: 16 << 30)
            XCTAssertEqual(sevenZip.longPoleThreads, requested >= 3 ? 2 : 0)
            XCTAssertLessThanOrEqual(sevenZip.codecThreads, requested)
            XCTAssertLessThanOrEqual(sevenZip.threads + sevenZip.longPoleThreads, requested)
        }
        let options = WriterOptions(sevenZipMethod: .lzma, lzmaLevel: 0, compressionThreads: 16)
        let configuration = try LZMAWriterConfiguration(options: options, raw: true, physicalMemory: 16 << 30)
        let reservation = configuration.memoryPerThread + UInt64(EntryCompressionConfiguration.inputLimit
            + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size + LZMAMatchFinderPipeline.memorySize)
        for (budget, expected) in [(2 * reservation - 1, 0), (2 * reservation, 2)] {
            EntryCompressionConfiguration.$testingMemoryBudget.withValue(budget) {
                XCTAssertEqual(EntryCompressionConfiguration(options: options, method: .lzma,
                    physicalMemory: 16 << 30).longPoleThreads, expected)
            }
        }
    }

    func testAutomaticThreadsUseAllActiveCoresAndGiBClamp() {
        let options = WriterOptions()
        for (cores, memory, expected) in [(16, UInt64(128 << 30), 16), (10, 16 << 30, 10),
                                        (32, 128 << 30, 32), (16, 4 << 30, 4), (0, 0, 1), (16, 1 << 29, 1)] {
            XCTAssertEqual(options.resolvedCompressionThreads(activeProcessorCount: cores, physicalMemory: memory), expected)
        }
        XCTAssertEqual(WriterOptions(compressionThreads: 64).resolvedCompressionThreads(activeProcessorCount: 16, physicalMemory: 1 << 30), 64)
    }

    func testSolidAndFilterWindowsReserveOnlyPossibleCodecs() {
        EntryCompressionConfiguration.$testingMemoryBudget.withValue(8 << 30) {
            for method: SevenZipCompressionMethod in [.lzma2, .lzma, .ppmd, .deflate, .copy] {
                for solid: SevenZipSolidMode in [.off, .on(blockSize: 64 << 20)] {
                    let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: solid,
                        sevenZipFilter: .delta(distance: 4), ppmdLevel: 9, compressionThreads: 12)
                    let configuration = EntryCompressionConfiguration(options: options, method: method,
                        physicalMemory: 16 << 30, innerParallelism: true)
                    XCTAssertEqual(configuration.threads, method == .lzma ? 10 : 12, "\(method), \(solid)")
                    XCTAssertEqual(configuration.codecThreads, method == .ppmd || method == .copy ? 13 : 12)
                    // 通常12枠と長いstreamの専用一枠。
                    let bound: UInt64 = solid != .off ? UInt64(method == .lzma ? 704 : 832) << 20 : UInt64(method == .lzma ? 176 : 208) << 20
                    XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), bound)
                }
            }
            // 既定solid上限でもApple / 自前LZMA2とLZMA1に12枠を用意する。
            let methods: [(SevenZipCompressionMethod, Int?)] = [(.lzma2, nil), (.lzma2, 6), (.lzma, nil)]
            for (method, level) in methods {
                let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(), lzmaLevel: level, compressionThreads: 12)
                XCTAssertEqual(EntryCompressionConfiguration(options: options, method: method,
                    physicalMemory: 16 << 30, innerParallelism: true).threads, method == .lzma ? 10 : 12)
                XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), UInt64(method == .lzma ? 704 : 832) << 20)
            }
        }
        // PPMd level 9は一folder一モデル。194 MiBの状態と18 MiBのI/Oで一枠212 MiB。
        EntryCompressionConfiguration.$testingMemoryBudget.withValue(848 << 20) {
            let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(blockSize: 64 << 20), ppmdLevel: 9, compressionThreads: 12)
            let configuration = EntryCompressionConfiguration(options: options, method: .ppmd,
                physicalMemory: 16 << 30, innerParallelism: true)
            XCTAssertEqual(configuration.threads, 3)
            XCTAssertEqual(configuration.codecThreads, 4)
            XCTAssertEqual(configuration.longPoleThreads, 1)
            XCTAssertEqual(UInt64(configuration.threads + configuration.longPoleThreads) * (212 << 20), 848 << 20)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 256 << 20)
        }
    }

    func testLongPoleReservationFallsBackAtMemoryBoundary() {
        let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(blockSize: 64 << 20), ppmdLevel: 9, compressionThreads: 12)
        for (budget, reserved, codecs, bound): (UInt64, Int, Int, UInt64) in [
            ((424 << 20) - 1, 0, 2, 64 << 20), (424 << 20, 1, 2, 128 << 20)
        ] {
            EntryCompressionConfiguration.$testingMemoryBudget.withValue(budget) {
                let configuration = EntryCompressionConfiguration(options: options, method: .ppmd,
                    physicalMemory: 16 << 30, innerParallelism: true)
                XCTAssertEqual(configuration.threads, 1)
                XCTAssertEqual(configuration.longPoleThreads, reserved)
                XCTAssertEqual(configuration.codecThreads, codecs)
                XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), bound)
            }
        }
    }

    func testPieceCeilingThreadCapAndMemoryPeak() {
        // Appleの状態130 MiB、I/O18 MiB。最後の短い片も一つに数え、最大片数は要求threadsまで。
        for (size, requested, budget, slots, codecs, pieces) in [
            (UInt64(16 << 20) + 1, 12, UInt64(834 << 20), 3, 5, 2),
            (256 << 20, 3, 816 << 20, 2, 3, 3),
            (16 << 20, 12, 444 << 20, 3, 2, 1)
        ] {
            EntryCompressionConfiguration.$testingMemoryBudget.withValue(budget) {
                let options = WriterOptions(sevenZipSolid: .on(blockSize: size), compressionThreads: requested)
                let configuration = EntryCompressionConfiguration(options: options, method: .lzma2,
                    physicalMemory: 16 << 30, innerParallelism: true)
                XCTAssertEqual(configuration.threads, slots)
                XCTAssertEqual(configuration.codecThreads, codecs)
                let live = min(codecs, slots * pieces)
                XCTAssertLessThanOrEqual(UInt64(live) * (130 << 20) + UInt64(slots + 1) * (18 << 20), budget)
            }
        }
        // 注入したchunk幅も既存の片境界として予約する。出力の区切りは変えない。
        EntryCompressionConfiguration.$testingMemoryBudget.withValue(556 << 20) {
            let options = WriterOptions(sevenZipSolid: .on(blockSize: 16 << 20), compressionThreads: 12)
            XCTAssertEqual(EntryCompressionConfiguration(options: options, method: .lzma2,
                physicalMemory: 16 << 30, innerParallelism: true, chunkSize: 8 << 20).threads, 2)
        }
    }
}
