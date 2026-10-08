import Foundation
import Synchronization
import XCTest
@testable import GyoshukuKit

final class WriterOptionsTopologyTests: XCTestCase {
    func testEveryPolicyPowerAndThermalCombination() {
        // active CPU、番号順の level、物理 GiB、通常値、減らした値を独立に固定する。
        let cases: [(Int, [Int], UInt64, Int, Int)] = [
            (10, [4, 6], 16, 10, 5),
            (12, [2, 4, 6], 16, 12, 6), (12, [2, 4, 6], 32, 12, 6),
            (16, [12, 4], 128, 16, 4), (18, [6, 12], 36, 18, 9),
            (36, [12, 24], 96, 36, 18), (36, [12, 24], 512, 36, 18),
            (64, [8, 24, 32], 1024, 64, 32), (128, [8, 24, 32, 64], 1024, 128, 64),
            (1, [1], 1, 1, 1), (18, [], 36, 18, 9),
            (17, [], 128, 17, 9), (18, [6, 12], 4, 4, 4), (1, [], 0, 1, 1)
        ]
        let policies: [CompressionPowerPolicy] = [.reduceInLowPowerMode, .reduceInLowPowerModeOrThermalPressure, .alwaysUseAllCores]
        let thermals: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for (cpus, levels, gib, normal, reduced) in cases {
            let topology = CPUTopology(activeLogicalCPUs: cpus,
                performanceLevels: levels.map { .init(logicalCPUs: $0, physicalCPUs: $0) })
            for policy in policies {
                for lowPower in [false, true] {
                    for thermal in thermals {
                        let shouldReduce: Bool
                        switch policy {
                        case .reduceInLowPowerMode: shouldReduce = lowPower
                        case .reduceInLowPowerModeOrThermalPressure:
                            shouldReduce = lowPower || thermal == .serious || thermal == .critical
                        case .alwaysUseAllCores: shouldReduce = false
                        }
                        XCTAssertEqual(WriterOptions.automaticCompressionThreads(topology: topology, physicalMemory: gib << 30,
                            lowPowerMode: lowPower, thermalState: thermal, policy: policy), shouldReduce ? reduced : normal,
                            "cpus=\(cpus), levels=\(levels), policy=\(policy), LPM=\(lowPower), thermal=\(thermal)")
                    }
                }
            }
        }
    }

    func testSysctlFallbackAndOrdinalLevels() {
        let values = ["hw.activecpu": 12, "hw.nperflevels": 3,
            "hw.perflevel0.logicalcpu": 2, "hw.perflevel0.physicalcpu": 2,
            "hw.perflevel1.logicalcpu": 4, "hw.perflevel1.physicalcpu": 4,
            "hw.perflevel2.logicalcpu": 6, "hw.perflevel2.physicalcpu": 6]
        var names: [String] = []
        let topology = CPUTopology.read(integer: { names.append($0); return values[$0] }, fallbackActiveCPUs: 99)
        XCTAssertEqual(topology.activeLogicalCPUs, 12)
        XCTAssertEqual(topology.performanceLevels.map(\.logicalCPUs), [2, 4, 6])
        XCTAssertEqual(topology.performanceLevels.map(\.physicalCPUs), [2, 4, 6])
        XCTAssertFalse(names.contains { $0.contains("name") })
        for missing in ["hw.nperflevels", "hw.perflevel2.logicalcpu", "hw.perflevel1.physicalcpu"] {
            let fallback = CPUTopology.read(integer: { $0 == missing ? nil : values[$0] }, fallbackActiveCPUs: 99)
            XCTAssertEqual(fallback.performanceLevels, [.init(logicalCPUs: 12, physicalCPUs: 12)])
        }
        let zero = CPUTopology.read(integer: { $0 == "hw.activecpu" ? 0 : nil }, fallbackActiveCPUs: 7)
        XCTAssertEqual(zero, .init(activeLogicalCPUs: 7))
        XCTAssertEqual(CPUTopology.read(integer: { _ in 0 }, fallbackActiveCPUs: 0), .init(activeLogicalCPUs: 1))
        XCTAssertEqual(CPUTopology.read(integer: { $0 == "hw.nperflevels" ? 0 : values[$0] }, fallbackActiveCPUs: 99), .init(activeLogicalCPUs: 12))
    }

    func testPoolSafetyScalesAndMemoryClampsRemain() throws {
        for (cpus, expected) in [(1, 16), (10, 16), (18, 22), (36, 45), (64, 80), (128, 160)] {
            XCTAssertEqual(CompressionWorkerPool.entryThreadLimit(activeCPUs: cpus, constrainedThreads: nil), expected)
        }
        XCTAssertEqual(CompressionWorkerPool.entryThreadLimit(activeCPUs: 128, constrainedThreads: 64), 16)
        XCTAssertEqual(CompressionWorkerPool.entryThreadLimit(activeCPUs: 128, constrainedThreads: 512), 128)
        XCTAssertEqual(CompressionWorkerPool.entryThreadLimit(activeCPUs: 1, constrainedThreads: 1), 1)
        XCTAssertEqual(CompressionWorkerPool.entryThreadLimit(activeCPUs: 36, constrainedThreads: 0), 45)
        for requested in [36, 64, 128, 1024] {
            let options = WriterOptions(compressionMethod: .ppmd, compressionThreads: requested)
            let limit = CompressionWorkerPool.entryThreadLimit(activeCPUs: requested, constrainedThreads: nil)
            EntryCompressionConfiguration.$testingEntryThreadLimit.withValue(limit) {
                XCTAssertEqual(EntryCompressionConfiguration(options: options, physicalMemory: 1 << 40).threads, requested)
                XCTAssertEqual(options.maximumPendingInputBytes(for: .zip, physicalMemory: 1 << 40), UInt64(requested) << 24)
            }
        }
        EntryCompressionConfiguration.$testingEntryThreadLimit.withValue(128) {
            EntryCompressionConfiguration.$testingMemoryBudget.withValue(72 << 20) {
                XCTAssertEqual(EntryCompressionConfiguration(options: .init(compressionThreads: 128), physicalMemory: 1 << 40).threads, 3)
            }
        }
        let many = WriterOptions(lzmaLevel: 0, memoryLimit: 8 << 30, compressionThreads: 1024)
        let lzma = try LZMAWriterConfiguration(options: many, physicalMemory: 32 << 30)
        XCTAssertGreaterThan(lzma.threads, 64)
        XCTAssertLessThanOrEqual(UInt64(lzma.threads) * lzma.memoryPerThread, lzma.memoryBudget)
        let zstd = try ZstdWriterConfiguration(options: many, physicalMemory: 32 << 30)
        XCTAssertGreaterThan(zstd.threads, 64)
        XCTAssertLessThanOrEqual(UInt64(zstd.threads) * zstd.memoryPerThread, zstd.memoryBudget)
    }

    func testPublicRangeAndExplicitThreadsIgnorePowerPolicy() throws {
        XCTAssertEqual(WriterOptions.compressionThreadsRange, 1...1024)
        XCTAssertEqual(WriterOptions().powerPolicy, .reduceInLowPowerMode)
        for threads in [1, 8, 36, 64, 128, 1024] {
            for policy: CompressionPowerPolicy in [.reduceInLowPowerMode, .reduceInLowPowerModeOrThermalPressure, .alwaysUseAllCores] {
                let options = WriterOptions(compressionThreads: threads, powerPolicy: policy)
                try options.validate(for: .zip)
                WriterOptions.$testingAutomaticThreads.withValue({ _ in XCTFail("明示値では状態を読まない"); return 1 }) {
                    XCTAssertEqual(options.resolvingCompressionThreads().resolvedCompressionThreads, threads)
                }
            }
        }
        for threads in [Int.min, -1, 0, 1025, Int.max] {
            XCTAssertThrowsError(try WriterOptions(compressionThreads: threads).validate(for: .zip)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("compressionThreads"))
            }
        }
        WriterOptions.$testingAutomaticThreads.withValue({ $0 == .alwaysUseAllCores ? 36 : 18 }) {
            XCTAssertEqual(WriterOptions.automaticCompressionThreads(), 18)
            XCTAssertEqual(WriterOptions.automaticCompressionThreads(powerPolicy: .alwaysUseAllCores), 36)
        }
    }

    func testSnapshotIsSharedByWritersAndUpdaters() throws {
        let root = try TestSupport.directory("topology-job-snapshot")
        for format: ArchiveFormat in [.zip, .sevenZip, .lha, .tar, .tarXZ, .tarBzip2, .tarZstd] {
            let state = Mutex((calls: 0, value: 8))
            let url = root.appendingPathComponent(UUID().uuidString)
            try WriterOptions.$testingAutomaticThreads.withValue({ _ in state.withLock { $0.calls += 1; return $0.value } }) {
                let writer = try ArchiveWriter.create(url: url, format: format)
                state.withLock { $0.value = 1 }
                for index in 0..<3 { try writer.add(data: Data(repeating: 65, count: 4096), as: "file-\(index)", modificationDate: TestSupport.date) }
                try writer.finishAdditions(progress: nil)
                try writer.finish()
                XCTAssertEqual(state.withLock { $0.calls }, 1, "writer \(format)")
            }
            for rewrite in [false, true] {
                state.withLock { $0 = (0, 8) }
                let output = root.appendingPathComponent(UUID().uuidString)
                try WriterOptions.$testingAutomaticThreads.withValue({ _ in state.withLock { $0.calls += 1; return $0.value } }) {
                    // 形式別 updater / rewriter は同じ snapshot を追加 writer と commit に渡す。
                    let editor = try AdditionProgressTestSupport.editor(url, output: output, format: format, options: .init(), rewrite: rewrite)
                    state.withLock { $0.value = 1 }
                    try editor.add(data: Data([66]), as: "new", modificationDate: TestSupport.date, permissions: nil)
                    try editor.commit()
                    XCTAssertEqual(state.withLock { $0.calls }, 1, "editor \(format), rewrite=\(rewrite)")
                }
            }
        }
    }

    func testSingleStreamSnapshotDoesNotReadPowerStateAgain() throws {
        let root = try TestSupport.directory("topology-single-stream-snapshot")
        let source = root.appendingPathComponent("source")
        try Data(repeating: 65, count: IOChunk.size + 1).write(to: source)
        for format in SingleStreamFormat.allCases {
            let state = Mutex((calls: 0, value: 8))
            try WriterOptions.$testingAutomaticThreads.withValue({ _ in state.withLock { $0.calls += 1; return $0.value } }) {
                try SingleStreamWriter.$testingDidRead.withValue({ _ in state.withLock { $0.value = 1 } }) {
                    try SingleStreamCompressor.compress(file: source, to: root.appendingPathComponent("output-\(format)"), format: format)
                }
                XCTAssertEqual(state.withLock { $0.calls }, 1, "single stream \(format)")
            }
        }
    }

    func testSevenZipEveryMethodSharesSnapshotWithPieceAndFolderPipelines() throws {
        let root = try TestSupport.directory("topology-sevenzip-snapshot")
        for method: SevenZipCompressionMethod in [.lzma2, .lzma, .deflate, .bzip2, .ppmd, .copy] {
            for solid: SevenZipSolidMode in [.off, .on(blockSize: 4096)] {
                let state = Mutex((calls: 0, value: 8))
                try WriterOptions.$testingAutomaticThreads.withValue({ _ in state.withLock { $0.calls += 1; return $0.value } }) {
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: .sevenZip,
                        options: .init(sevenZipMethod: method, sevenZipSolid: solid, lzmaLevel: 0))
                    state.withLock { $0.value = 1 }
                    for index in 0..<3 { try writer.add(data: Data(repeating: 65, count: 4096), as: "file-\(index)", modificationDate: TestSupport.date) }
                    try writer.finish()
                    XCTAssertEqual(state.withLock { $0.calls }, 1, "\(method), \(solid)")
                }
            }
        }
    }
}
