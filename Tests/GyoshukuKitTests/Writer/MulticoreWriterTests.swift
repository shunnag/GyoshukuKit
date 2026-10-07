import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class MulticoreWriterTests: XCTestCase {
    private let payload = Data(String(repeating: "ordered writer: source, binary, checksum\n", count: 1800).utf8)

    private func write(_ url: URL, format: GyoshukuKit.ArchiveFormat, options: WriterOptions, batch: Bool = false) throws {
        try EncryptionPrimitives.$testingRandomBytes.withValue({ Data(repeating: 0x37, count: $0) }) {
            try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 0x53, count: 16) }) {
                let writer = try ArchiveWriter.create(url: url, format: format, options: options,
                    zipSalt: { Data(repeating: 0x37, count: 16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                if batch {
                    let input = url.deletingLastPathComponent().appendingPathComponent("input")
                    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
                    let additions = try (0..<15).map { index in
                        let source = input.appendingPathComponent("file-\(index).dat")
                        try payload.write(to: source)
                        try AdditionProgressTestSupport.timestamp(source)
                        // png も指定し、heuristic の stored と圧縮項目の混在を検査する。
                        return ArchiveAddition(path: index == 7 ? "file-7.png" : "file-\(index)", source: .contents(of: source))
                    }
                    var finished: [Int] = []
                    try writer.add(additions) { event in
                        if case let .didFinish(index) = event { finished.append(index) }
                    }
                    XCTAssertEqual(finished, Array(0..<15))
                } else {
                    for index in 0..<15 {
                        try writer.add(data: index == 7 ? Data() : payload, as: "file-\(index)", modificationDate: TestSupport.date)
                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: format))
                    }
                    let pending = writer.pendingInputBytes
                    var progress: [ArchiveUpdater.CommitProgress] = []
                    try writer.finishAdditions { progress.append($0) }
                    XCTAssertEqual(progress.last?.completedBytes, pending)
                    XCTAssertEqual(writer.pendingInputBytes, 0)
                }
                try writer.finish()
            }
        }
    }

    func testZIPOrderedEntriesAndEncryptionAreThreadIndependent() throws {
        let root = try TestSupport.directory("multicore-zip")
        for method: CompressionMethod in [.bzip2, .lzma, .xz, .zstd, .ppmd] {
            for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                var baseline: Data?
                for threads in [1, 4] {
                    let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                    let options = WriterOptions(compressionMethod: method, password: encryption == nil ? nil : "secret",
                                                zipEncryption: encryption ?? .aes256, compressionThreads: threads)
                    try write(url, format: .zip, options: options)
                    let bytes = try Data(contentsOf: url)
                    if let baseline { XCTAssertEqual(bytes, baseline, "\(method) / \(String(describing: encryption))") }
                    else { baseline = bytes }
                    try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path] + (options.password.map { ["-p" + $0] } ?? []), in: root, log: "oracle")
                    let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: options.password))
                    XCTAssertEqual(reader.entries.map(\.name), (0..<15).map { "file-\($0)" })
                    for (index, entry) in reader.entries.enumerated() {
                        XCTAssertEqual(try reader.read(entry), index == 7 ? Data() : payload)
                    }
                }
            }
        }
    }

    func testZIPBatchHeuristicAndProgressOrder() throws {
        let root = try TestSupport.directory("multicore-zip-batch")
        for method: CompressionMethod in [.bzip2, .lzma, .xz, .zstd, .ppmd] {
            var baseline: Data?
            for threads in [1, 4] {
                let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                try write(url, format: .zip, options: .init(compressionMethod: method, compressionThreads: threads), batch: true)
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method)") } else { baseline = bytes }
                let reader = try ArchiveReader.open(url: url)
                for entry in reader.entries { XCTAssertEqual(try reader.read(entry), payload) }
            }
        }
    }

    func testSevenZipFoldersSolidFiltersAndAESAreThreadIndependent() throws {
        let root = try TestSupport.directory("multicore-7z")
        for method: SevenZipCompressionMethod in [.lzma2, .lzma, .deflate, .bzip2, .ppmd, .copy] {
            for solid in [false, true] {
                for filter: SevenZipFilterMode in [.none, .bcjX86, .arm64, .delta(distance: 4)] {
                    var baseline: Data?
                    for threads in [1, 4] {
                        let url = root.appendingPathComponent(UUID().uuidString + ".7z")
                        let options = WriterOptions(sevenZipMethod: method,
                            sevenZipSolid: solid ? .on(blockSize: 256 << 10, filesPerBlock: 3) : .off,
                            sevenZipFilter: filter, password: "secret", encryptsSevenZipHeaders: true, compressionThreads: threads)
                        try write(url, format: .sevenZip, options: options)
                        let bytes = try Data(contentsOf: url)
                        if let baseline { XCTAssertEqual(bytes, baseline, "\(method) / \(solid) / \(filter)") } else { baseline = bytes }
                        try ReferenceTool.run(ReferenceTool.sevenZip, ["t", "-psecret", url.path], in: root, log: "oracle")
                        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: "secret"))
                        for (index, entry) in reader.entries.enumerated() {
                            XCTAssertEqual(try reader.read(entry), index == 7 ? Data() : payload)
                        }
                    }
                }
            }
        }
    }

    func testEntryMemoryReservationsKeepSequentialFallback() throws {
        for method: CompressionMethod in [.lzma, .zstd] {
            let options = WriterOptions(compressionMethod: method, compressionThreads: 12)
            let state = method == .lzma ? try LZMAWriterConfiguration(options: options, raw: true).memoryPerThread
                : try ZstdWriterConfiguration(options: options, streaming: true).memoryPerThread
            var limited = options
            limited.memoryLimit = state
            XCTAssertNoThrow(try limited.validate(for: .zip))
            XCTAssertEqual(EntryCompressionConfiguration(options: limited).threads, 1)
            XCTAssertEqual(limited.maximumPendingInputBytes(for: .zip), 0)
            limited.memoryLimit = 2 * (state + UInt64(EntryCompressionConfiguration.inputLimit + 4 * IOChunk.size))
            XCTAssertEqual(EntryCompressionConfiguration(options: limited).threads, 2)
        }
    }

    func testLHAMediumMembersKeepIdentityProgressAndStoredFallback() throws {
        let root = try TestSupport.directory("multicore-lha")
        let medium = Data((String(repeating: "member history and continuous bits\n", count: 70_000)).utf8)
        let random = LHATestSupport.random(2 << 20)
        let items: [LHATestSupport.Expected] = [
            .init(name: "before", data: Data([1])),
            .init(name: "first", data: medium), .init(name: "second", data: medium),
            .init(name: "random", data: random), .init(name: "middle", data: Data([2])),
            .init(name: "third", data: medium)
        ]
        for method: LHACompressionMethod in [.lh5, .lh6, .lh7] {
            var baseline: Data?
            for threads in [1, 4] {
                let directory = try TestSupport.work(in: root)
                let url = directory.appendingPathComponent("archive.lzh")
                let options = WriterOptions(lhaMethod: method, compressionThreads: threads)
                let writer = try ArchiveWriter.create(url: url, format: .lha, options: options)
                for item in items {
                    try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                    XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .lha))
                }
                let pending = writer.pendingInputBytes
                if threads > 1 { XCTAssertGreaterThan(pending, 0) }
                var progress: [ArchiveUpdater.CommitProgress] = []
                try writer.finishAdditions { progress.append($0) }
                XCTAssertEqual(progress.last?.completedBytes, pending)
                try writer.finish()
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertTrue(bytes == baseline, "\(method)") } else { baseline = bytes }
                XCTAssertEqual(try LHABytes(bytes).members[3].method, "-lh0-")
                try LHATestSupport.verify(url, expected: items)
            }
        }
    }

    func testQueuedEntriesCancelAndReleaseSpools() async throws {
        let root = try TestSupport.directory("multicore-cancellation")
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] {
            let url = root.appendingPathComponent(UUID().uuidString)
            let task = Task.detached {
                let options = WriterOptions(compressionMethod: .ppmd, sevenZipMethod: .ppmd,
                                            sevenZipSolid: format == .sevenZip ? .on(blockSize: 512 << 10) : .off,
                                            compressionThreads: 4)
                let writer = try ArchiveWriter.create(url: url, format: format, options: options,
                    zipSalt: { Data(repeating: 0x37, count: 16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                try writer.add(data: Data(repeating: 65, count: format == .lha ? 2 << 20 : 512 << 10), as: "first")
                XCTAssertGreaterThan(writer.pendingInputBytes, 0)
                withUnsafeCurrentTask { $0?.cancel() }
                try writer.finishAdditions(progress: { _ in })
            }
            do { try await task.value; XCTFail("expected cancellation") }
            catch is CancellationError {}
            if format != .zip { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gyoshuku-") })
        }
    }
}
