import Foundation
@_spi(Parallelism) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class SpeedPriorityTests: XCTestCase {
    private let policies: [CompressionPowerPolicy] = [.reduceInLowPowerMode, .reduceInLowPowerModeOrThermalPressure, .alwaysUseAllCores]

    func testPieceSizeTablesAndEnvironmentIndependence() throws {
        XCTAssertFalse(WriterOptions().prefersSpeed)
        let sizes: [UInt64] = [0, 1 << 20, 10 << 20, 64 << 20, 256 << 20, 1 << 30]
        for level: Int? in [nil, 0, 6, 8, 9] {
            let standard = level == 8 ? 96 : level == 9 ? 192 : 16
            let expected = [standard, 2, 2, 4, 16, min(standard, 64)]
            for (index, size) in sizes.enumerated() {
                for threads in [1, 4, 16, 36] {
                    for memory: UInt64 in [2 << 30, 32 << 30] {
                        let options = WriterOptions(lzmaLevel: level, prefersSpeed: true, memoryLimit: memory, compressionThreads: threads)
                        let configuration = try LZMAWriterConfiguration(options: options, size: size, physicalMemory: 64 << 30)
                        XCTAssertEqual(configuration.pieceSize, expected[index] << 20, "level=\(String(describing: level)), S=\(size)")
                        if level != nil {
                            XCTAssertEqual(configuration.memoryPerThread, UInt64(configuration.encoderMemory + 2 * configuration.pieceSize))
                            XCTAssertLessThanOrEqual(UInt64(configuration.threads) * configuration.memoryPerThread, memory)
                        }
                        var ratio = options; ratio.prefersSpeed = false
                        XCTAssertEqual(try LZMAWriterConfiguration(options: ratio, size: size, physicalMemory: 64 << 30).pieceSize, standard << 20)
                    }
                }
            }
        }
        for (level, dictionary, standard) in [(0, 1, 16), (6, 8, 24), (9, 64, 192)] {
            let expected = [standard, max(2, dictionary), max(2, dictionary), max(4, dictionary), max(16, dictionary), max(min(standard, 64), dictionary)]
            for (index, size) in sizes.enumerated() {
                let options = WriterOptions(lzmaLevel: level, prefersSpeed: true, compressionThreads: 36)
                let configuration = try LZMAWriterConfiguration.singleStream(options: options, lzip: true, size: size)
                XCTAssertEqual(configuration.pieceSize, expected[index] << 20, "lzip level=\(level), S=\(size)")
            }
        }
        XCTAssertEqual(CompressionPieceSize.resolve(standard: 16 << 20, size: UInt64.max, prefersSpeed: true), 16 << 20)
        XCTAssertEqual(CompressionPieceSize.resolve(standard: 16 << 20, size: (32 << 20) + 1, prefersSpeed: true), 3 << 20)
        for method: SevenZipCompressionMethod in [.lzma, .lzma2, .ppmd, .bzip2, .deflate] {
            XCTAssertEqual(WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(), prefersSpeed: true).resolvedSevenZipBlockSize, 16 << 20)
            XCTAssertEqual(WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(blockSize: 71 << 20), prefersSpeed: true).resolvedSevenZipBlockSize, 71 << 20)
        }
    }

    // 明示並列数に加え、異なるCPU・電力・温度・メモリの自動要求値を各方針で使う。
    private func variants(_ base: WriterOptions) -> [WriterOptions] {
        var result = [1, 4, 16, 36].map { threads in
            var options = base; options.prefersSpeed = true; options.compressionThreads = threads
            return options
        }
        for policy in policies {
            var options = base; options.prefersSpeed = true; options.compressionThreads = nil; options.powerPolicy = policy
            result.append(options)
        }
        var tight = base; tight.prefersSpeed = true; tight.compressionThreads = 36; tight.memoryLimit = base.lzmaLevel == 6 ? 192 << 20 : 128 << 20
        result.append(tight)
        return result
    }

    private func withTopology<T>(_ body: () throws -> T) rethrows -> T {
        try WriterOptions.$testingAutomaticThreads.withValue({ policy in
            let lowPower = policy == .reduceInLowPowerMode
            let topology = CPUTopology(activeLogicalCPUs: lowPower ? 16 : 36,
                performanceLevels: lowPower ? [.init(logicalCPUs: 12, physicalCPUs: 12), .init(logicalCPUs: 4, physicalCPUs: 4)] : [])
            return WriterOptions.automaticCompressionThreads(topology: topology, physicalMemory: lowPower ? 8 << 30 : 96 << 30,
                lowPowerMode: lowPower, thermalState: .serious, policy: policy)
        }, operation: body)
    }

    func testArchivesAcrossThreadsAndPowerPolicies() throws {
        let directory = try TestSupport.directory("speed-priority-archives")
        let items = [ExpectedEntry(name: "medium", data: SpeedPriorityDefaultOutputTests.medium),
                     .init(name: "large", data: SpeedPriorityDefaultOutputTests.large),
                     .init(name: "last", data: SpeedPriorityDefaultOutputTests.medium)]
        for (name, format, base) in SpeedPriorityDefaultOutputTests.configurations {
            var baseline: Data?
            for (index, options) in variants(base).enumerated() {
                let url = directory.appendingPathComponent("\(index)-\(name)")
                try withTopology {
                    let writer = try ArchiveWriter.create(url: url, format: format, options: options)
                    for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                    var last: UInt64 = .max
                    try writer.finishAdditions { progress in
                        XCTAssertLessThanOrEqual(progress.totalBytes, options.maximumPendingInputBytes(for: format))
                        XCTAssertLessThanOrEqual((progress.totalBytes - progress.completedBytes), last)
                        last = (progress.totalBytes - progress.completedBytes)
                    }
                    try writer.finish()
                }
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(name), variant=\(index)") } else { baseline = bytes }
                if index == 0 {
                    try TestSupport.assertKaitoKitRoundTrip(url, expected: items)
                    if format == .tarXZ || format == .tarLzip {
                        XCTAssertEqual(bytes, try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("speed-priority/" + name)), "未知のtar総入力では従来幅を保つ")
                    }
                    let tool = format == .tarXZ ? ReferenceTool.xz : format == .tarLzip ? ReferenceTool.lzip : ReferenceTool.sevenZip
                    try ReferenceTool.run(tool, [tool == ReferenceTool.sevenZip ? "t" : "-t", url.path], in: directory, log: name + "-test")
                    if format == .zip { try verifyZipPayload(url, method: base.compressionMethod, size: items[0].data.count, directory: directory) }
                    if format == .sevenZip, base.sevenZipSolid != .off {
                        let listing = try ReferenceTool.run(ReferenceTool.sevenZip, ["l", "-slt", url.path], in: directory, log: name + "-list")
                        XCTAssertTrue(listing.utf8Text.contains("Blocks = 3"), listing.utf8Text)
                    }
                }
            }
        }
    }

    private func verifyZipPayload(_ url: URL, method: CompressionMethod, size: Int, directory: URL) throws {
        let zip = ZipBytes(data: try Data(contentsOf: url))
        let start = 30 + Int(zip.u16(26)) + Int(zip.u16(28))
        let payload = zip.data.subdata(in: start..<(start + Int(zip.u32(18))))
        let stream = directory.appendingPathComponent(url.lastPathComponent + (method == .zstd ? ".zst" : ".xz"))
        try payload.write(to: stream)
        try ReferenceTool.run(method == .zstd ? ReferenceTool.zstd : ReferenceTool.xz, ["-t", stream.path], in: directory, log: stream.lastPathComponent + "-test")
        if method == .zstd {
            XCTAssertEqual(try ZstdWriterTestSupport.frames(payload).map(\.contentSize), [4 << 20, 4 << 20, UInt64(size - (8 << 20))])
        }
    }

    func testSingleFilesAcrossThreadsAndPowerPolicies() throws {
        let directory = try TestSupport.directory("speed-priority-single")
        let input = SpeedPriorityDefaultOutputTests.medium
        let source = directory.appendingPathComponent("source.raw")
        try input.write(to: source)
        for (name, format, base): (String, SingleStreamFormat, WriterOptions) in [
            ("apple.xz", .xz, .init()), ("own.xz", .xz, .init(lzmaLevel: 0)),
            ("small-dict.lz", .lzip, .init(lzmaLevel: 0)), ("preset6.lz", .lzip, .init(lzmaLevel: 6))
        ] {
            var baseline: Data?
            for (index, options) in variants(base).enumerated() {
                let url = directory.appendingPathComponent("\(index)-\(name)")
                try withTopology { try SingleStreamCompressor.compress(file: source, to: url, format: format, options: options) }
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(name), variant=\(index)") } else { baseline = bytes }
                if index == 0 {
                    try StreamEncoderTestSupport.assertKaito(url, equals: input)
                    try ReferenceTool.run(format == .xz ? ReferenceTool.xz : ReferenceTool.lzip, ["-t", url.path], in: directory, log: name + "-test")
                    if format == .lzip { XCTAssertEqual(try SingleStreamTestSupport.lzipMemberRanges(bytes).count, base.lzmaLevel == 6 ? 2 : 5) }
                    else {
                        let listing = try ReferenceTool.run(ReferenceTool.xz, ["--robot", "-l", url.path], in: directory, log: name + "-list")
                        XCTAssertTrue(listing.utf8Text.contains("file\t1\t5\t"), listing.utf8Text)
                    }
                }
            }
        }
    }

    func testZipDiskBatchAndEncryptionUseTheSamePieces() throws {
        let root = try TestSupport.directory("speed-priority-zip-batch")
        for input in [SpeedPriorityDefaultOutputTests.medium, SpeedPriorityDefaultOutputTests.large] {
            let directory = try TestSupport.work(in: root)
            let source = directory.appendingPathComponent("source")
            try input.write(to: source)
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: source.path)
            for method: CompressionMethod in [.xz, .zstd] {
                for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                    var baseline: Data?
                    for (index, threads) in [1, 4, 16, 36].enumerated() {
                        let url = directory.appendingPathComponent("\(method)-\(String(describing: encryption))-\(threads).zip")
                        let options = WriterOptions(compressionMethod: method, lzmaLevel: 0, prefersSpeed: true,
                            useCompressionHeuristic: false, password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256, compressionThreads: threads)
                        // 固定saltは圧縮byteの比較だけに使う。通常の暗号乱数の契約は変えない。
                        try EncryptionPrimitives.$testingRandomBytes.withValue({ Data(repeating: 0x42, count: $0) }) {
                            let writer = try ArchiveWriter.create(url: url, format: .zip, options: options, zipSalt: { Data(count: 16) }, lzmaChunkSize: nil)
                            if index == 0 { try writer.add(data: input, as: "large", modificationDate: TestSupport.date) }
                            else { try writer.add([.init(path: "large", source: .contents(of: source))], events: nil) }
                            try writer.finish()
                        }
                        let bytes = try Data(contentsOf: url)
                        if let baseline { XCTAssertEqual(bytes, baseline, "\(method), encryption=\(String(describing: encryption)), threads=\(threads)") } else { baseline = bytes }
                        if index == 1 {
                            try TestSupport.assertKaitoKitRoundTrip(url, expected: [.init(name: "large", data: input)], password: options.password)
                            try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path] + (options.password.map { ["-p\($0)"] } ?? []), in: directory, log: url.lastPathComponent + "-test")
                            if encryption == nil, method == .zstd {
                                let zip = ZipBytes(data: bytes), start = 30 + Int(ZipBytes(data: bytes).u16(26)) + Int(ZipBytes(data: bytes).u16(28))
                                let frames = try ZstdWriterTestSupport.frames(bytes.subdata(in: start..<(start + Int(zip.u32(18)))))
                                let expected = stride(from: 0, to: input.count, by: 4 << 20).map { UInt64(min(4 << 20, input.count - $0)) }
                                XCTAssertEqual(frames.map(\.contentSize), expected)
                            }
                        }
                    }
                }
            }
        }
    }

    func testSpeedZstdZIP64ReservesEachFrameHeader() throws {
        let directory = try TestSupport.directory("speed-priority-zip64")
        // 単一frameの上界はUInt32内、1024 frameのheaderを含めるとZIP64が必要になる入力長。
        let size = UInt64(UInt32.max) - 110_000
        for speed in [false, true] {
            let url = directory.appendingPathComponent("\(speed).zip")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writer = ZipWriter(output: try FileHandle(forWritingTo: url), url: url,
                options: .init(compressionMethod: .zstd, prefersSpeed: speed, compressionThreads: 1),
                deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
            let entry = try writer.makeEntry(name: "near-limit", mode: 0o100644, size: size,
                date: TestSupport.date, atime: nil, owners: nil)
            XCTAssertEqual(entry.reservedZIP64, speed)
        }
    }

    func testZstdFrameThresholdAndLargeWindow() throws {
        for (level, size, expected): (Int, Int, [UInt64]) in [
            (3, 4 << 20, [4 << 20]), (3, (4 << 20) + 1, [4 << 20, 1]),
            (13, 10 << 20, [8 << 20, 2 << 20])
        ] {
            let input = Data(repeating: 0x41, count: size)
            var offset = 0, output = Data()
            _ = try ZipEntryCompressor(options: .init(compressionMethod: .zstd, zstdLevel: level,
                prefersSpeed: true, compressionThreads: 4)).compress(name: "window", size: UInt64(size), method: .zstd,
                read: { count in
                    let end = min(size, offset + count)
                    defer { offset = end }
                    return input.subdata(in: offset..<end)
                }, emit: { output.append($0) })
            XCTAssertEqual(try ZstdWriterTestSupport.frames(output).map(\.contentSize), expected)
        }
    }

    func testMediumBatchXZActuallyUsesFourPieceWorkers() async throws {
        let directory = try TestSupport.directory("speed-priority-medium-workers")
        let source = directory.appendingPathComponent("source")
        try SpeedPriorityDefaultOutputTests.medium.write(to: source)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try ZipWriter.$testingBatchXZEncoder.withValue({ input in
                started.signal(); release.wait()
                return try LZMA2Compressor.encode(input)
            }) {
                let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("archive.zip"),
                    options: .init(compressionMethod: .xz, prefersSpeed: true, compressionThreads: 4))
                try writer.add([.init(path: "medium", source: .contents(of: source))], events: nil)
                try writer.finish()
            }
        }
        defer { for _ in 0..<5 { release.signal() } }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(started) }
        for _ in 0..<5 { release.signal() }
        try await task.value
    }

}
