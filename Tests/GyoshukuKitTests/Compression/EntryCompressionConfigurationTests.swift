import Foundation
import XCTest
@testable import GyoshukuKit

final class EntryCompressionConfigurationTests: XCTestCase {
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
                    XCTAssertEqual(configuration.threads, 12, "\(method), \(solid)")
                    XCTAssertEqual(configuration.codecThreads, 12)
                    // PPMd level 9の既定block上限384 MiBはfilter付き非solidも既存の同期経路。
                    let bound: UInt64 = solid != .off ? 768 << 20 : method == .ppmd ? 16 << 20 : 192 << 20
                    XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), bound)
                }
            }
            // 既定solid上限でもApple / 自前LZMA2とLZMA1に12枠を用意する。
            let methods: [(SevenZipCompressionMethod, Int?)] = [(.lzma2, nil), (.lzma2, 6), (.lzma, nil)]
            for (method, level) in methods {
                let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(), lzmaLevel: level, compressionThreads: 12)
                XCTAssertEqual(EntryCompressionConfiguration(options: options, method: method,
                    physicalMemory: 16 << 30, innerParallelism: true).threads, 12)
                XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 768 << 20)
            }
        }
        // PPMd level 9は一folder一モデル。194 MiBの状態と18 MiBのI/Oで一枠212 MiB。
        EntryCompressionConfiguration.$testingMemoryBudget.withValue(848 << 20) {
            let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(blockSize: 64 << 20), ppmdLevel: 9, compressionThreads: 12)
            let configuration = EntryCompressionConfiguration(options: options, method: .ppmd,
                physicalMemory: 16 << 30, innerParallelism: true)
            XCTAssertEqual(configuration.threads, 4)
            XCTAssertEqual(configuration.codecThreads, 4)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 256 << 20)
        }
    }

    func testPieceCeilingThreadCapAndMemoryPeak() {
        // Appleの状態130 MiB、I/O18 MiB。最後の短い片も一つに数え、最大片数は要求threadsまで。
        for (size, requested, budget, slots, codecs, pieces) in [
            (UInt64(16 << 20) + 1, 12, UInt64(834 << 20), 3, 6, 2),
            (256 << 20, 3, 816 << 20, 2, 3, 3),
            (16 << 20, 12, 444 << 20, 3, 3, 1)
        ] {
            EntryCompressionConfiguration.$testingMemoryBudget.withValue(budget) {
                let options = WriterOptions(sevenZipSolid: .on(blockSize: size), compressionThreads: requested)
                let configuration = EntryCompressionConfiguration(options: options, method: .lzma2,
                    physicalMemory: 16 << 30, innerParallelism: true)
                XCTAssertEqual(configuration.threads, slots)
                XCTAssertEqual(configuration.codecThreads, codecs)
                let live = min(codecs, slots * pieces)
                XCTAssertLessThanOrEqual(UInt64(live) * (130 << 20) + UInt64(slots) * (18 << 20), budget)
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
