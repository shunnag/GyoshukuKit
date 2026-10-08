import Foundation
import Synchronization
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
            limited.memoryLimit = 2 * (state + UInt64(EntryCompressionConfiguration.inputLimit + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size))
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

    func testLHAMixedTinyMembersKeepMemorySpoolsAndEncoderFailure() throws {
        let root = try TestSupport.directory("multicore-lha-tiny")
        let created = Mutex(0)
        try ScratchFile.$testingCreated.withValue({ _ in created.withLock { $0 += 1 } }) {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("tiny.lzh"), format: .lha,
                options: .init(compressionThreads: 4))
            try writer.add(data: Data(repeating: 65, count: 2 << 20), as: "medium", modificationDate: TestSupport.date)
            for index in 0..<100 {
                try writer.add(data: Data([65]), as: "tiny-\(index)", modificationDate: TestSupport.date)
                if index % 5 == 0 { try writer.addDirectory("folder-\(index)") }
            }
            try writer.finish()
        }
        // 中memberの完成recordと片連結用だけ。小member・directoryはfileを作らない。
        XCTAssertEqual(created.withLock { $0 }, 2)
        let reader = try ArchiveReader.open(url: root.appendingPathComponent("tiny.lzh"))
        XCTAssertEqual(reader.entries.count, 121)
        let calls = Mutex(0)
        let failed = root.appendingPathComponent("failure.lzh")
        let writer = try ArchiveWriter.create(url: failed, format: .lha, options: .init(compressionThreads: 4),
            lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize, lh5Encoder: { _ in
                calls.withLock { $0 += 1 }
                throw WriterError.compression(-77)
            })
        try writer.add(data: Data(repeating: 65, count: 2 << 20), as: "medium", modificationDate: TestSupport.date)
        try writer.add(data: Data([66]), as: "tiny", modificationDate: TestSupport.date)
        XCTAssertThrowsError(try writer.finishAdditions(progress: nil)) {
            XCTAssertEqual($0 as? WriterError, .compression(-77))
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    func testZIPInlineItemsKeepEntryWindowAndIdentity() throws {
        let root = try TestSupport.directory("multicore-zip-inline")
        for method: CompressionMethod in [.zstd, .bzip2, .lzma, .xz, .ppmd] {
            var baseline: Data?
            for threads in [1, 12] {
                let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                let writer = try ArchiveWriter.create(url: url, format: .zip,
                    options: .init(compressionMethod: method, compressionThreads: threads))
                try writer.add(data: payload, as: "first", modificationDate: TestSupport.date)
                let first = writer.pendingInputBytes
                try writer.add(data: Data(), as: "empty", modificationDate: TestSupport.date)
                try writer.addDirectory("folder", modificationDate: TestSupport.date, ownerIDs: nil)
                let stored = Data(repeating: 7, count: 4096)
                try writer.add(data: stored, as: "stored.png", modificationDate: TestSupport.date)
                var link = Data("first".utf8)
                try writer.addEntry(path: "link", mode: FileMode.defaultSymlink, size: UInt64(link.count),
                    date: TestSupport.date, atime: nil, owners: nil) { _ in
                    defer { link = Data() }
                    return link
                }
                if threads > 1 { XCTAssertEqual(writer.pendingInputBytes, first + UInt64(stored.count + 5)) }
                try writer.add(data: payload, as: "last", modificationDate: TestSupport.date)
                try writer.finish()
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method)") } else { baseline = bytes }
            }
        }
    }

    func testZIPBatchDirectoryURLAndLargeStoredKeepIdentityAndEvents() throws {
        let root = try TestSupport.directory("multicore-zip-tree-batch")
        let folder = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in [("first", payload), ("middle-empty", Data()), ("stored.png", payload), ("last", payload)] {
            try data.write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("subdirectory"), withIntermediateDirectories: true)
        let large = root.appendingPathComponent("large.png")
        try Data(repeating: 7, count: DeflateBlock.size + 1).write(to: large)
        for method: CompressionMethod in [.zstd, .bzip2] {
            var baseline: Data?
            for threads in [1, 12] {
                for file in [folder, large] + (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) {
                    try AdditionProgressTestSupport.timestamp(file)
                }
                let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                let writer = try ArchiveWriter.create(url: url, format: .zip, options: .init(compressionMethod: method, compressionThreads: threads))
                var finished: [Int] = []
                try writer.add([.init(path: "folder", source: .contents(of: folder)), .init(path: "large.png", source: .contents(of: large))]) {
                    if case let .didFinish(index) = $0 { finished.append(index) }
                }
                XCTAssertEqual(finished, [0, 1])
                XCTAssertEqual(writer.pendingInputBytes, 0)
                try writer.finish()
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method)") } else { baseline = bytes }
            }
        }
    }

    func testZIPOnlyEntryFinishesWithoutDiskSpool() throws {
        let root = try TestSupport.directory("multicore-zip-only")
        let input = LHATestSupport.random(2 << 20)
        for finishAdditions in [false, true] {
            let created = Mutex(0)
            try ScratchFile.$testingCreated.withValue({ _ in created.withLock { $0 += 1 } }) {
                let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                let writer = try ArchiveWriter.create(url: url, format: .zip,
                    options: .init(compressionMethod: .zstd, compressionThreads: 12))
                try writer.add(data: input, as: "only", modificationDate: TestSupport.date)
                XCTAssertEqual(writer.pendingInputBytes, UInt64(input.count))
                if finishAdditions {
                    var progress: [ArchiveUpdater.CommitProgress] = []
                    try writer.finishAdditions { progress.append($0) }
                    XCTAssertEqual(progress.last?.completedBytes, UInt64(input.count))
                    XCTAssertEqual(writer.pendingInputBytes, 0)
                }
                try writer.finish()
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(try reader.read(reader.entries[0]), input)
            }
            XCTAssertEqual(created.withLock { $0 }, 0)
        }
    }

    func testSmallBudgetEntryWindowBoundsIncludingWaitingAndSolidBlock() throws {
        let root = try TestSupport.directory("multicore-small-budget")
        let limit = LHAWriter.compressionChunkSize + 4096
        try EntryCompressionConfiguration.$testingInputLimit.withValue(limit) {
            for format: GyoshukuKit.ArchiveFormat in [.zip, .lha, .sevenZip] {
                let options = WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .deflate,
                    sevenZipSolid: .on(blockSize: UInt64(limit), filesPerBlock: nil), compressionThreads: 12)
                let state: UInt64 = switch format {
                case .zip: UInt64(400_000 + 8 * 100_000 * options.bzip2Level)
                case .lha: UInt64(8 << 20) * 12
                default: UInt64(4 << 20) * 12
                }
                let budget = 2 * (state + UInt64(limit + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size))
                try EntryCompressionConfiguration.$testingMemoryBudget.withValue(budget) {
                    let slots: Int = switch format {
                    case .zip: EntryCompressionConfiguration(options: options).threads
                    case .lha: EntryCompressionConfiguration(lhaThreads: 12).threads
                    default: EntryCompressionConfiguration(options: options, method: .deflate, innerParallelism: true).threads
                    }
                    XCTAssertEqual(slots, 2)
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: format, options: options)
                    let bound = UInt64(2 * limit)
                    var reached: UInt64 = 0
                    // waiting member と組立中 folder も含め、二枠をほぼ満たしてから跨ぐ。
                    for index in 0..<5 {
                        let size = limit - index
                        try writer.add(data: Data(repeating: UInt8(65 + index), count: size), as: "file-\(index)", modificationDate: TestSupport.date)
                        let pending = writer.pendingInputBytes
                        if index == 0 { XCTAssertEqual(pending, UInt64(size)) }
                        reached = max(reached, pending)
                        XCTAssertLessThanOrEqual(pending, bound, "\(format), item \(index)")
                        XCTAssertLessThanOrEqual(pending, options.maximumPendingInputBytes(for: format))
                    }
                    XCTAssertGreaterThanOrEqual(reached, bound - 8)
                    let pending = writer.pendingInputBytes
                    var progress: [ArchiveUpdater.CommitProgress] = []
                    try writer.finishAdditions { progress.append($0) }
                    XCTAssertEqual(progress.last?.completedBytes, pending)
                    XCTAssertEqual(writer.pendingInputBytes, 0)
                    try writer.finish()
                }
            }
        }
    }

    func testMediumEntryWindowBoundsAfterEveryAddition() throws {
        try checkMediumBounds(threads: 2, sizes: [1_048_577, 1_200_001, 1_300_003])
    }

    func testNearLimitEntryWindowBoundsAfterEveryAddition() throws {
        try OptInGate.flag("GYOSHUKU_MULTICORE_BENCHMARK")
        // t+1 個で満杯の窓を跨ぎ、16 MiB 直前の入力も検査する。
        try checkMediumBounds(threads: 12, sizes: (0..<13).map { $0 % 2 == 0 ? 16_777_215 : 16_776_959 })
    }

    private func checkMediumBounds(threads: Int, sizes: [Int]) throws {
        let root = try TestSupport.directory("multicore-medium-bounds")
        let options = WriterOptions(compressionMethod: .zstd, sevenZipMethod: .bzip2, compressionThreads: threads)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] {
            let url = root.appendingPathComponent(UUID().uuidString)
            let writer = try ArchiveWriter.create(url: url, format: format, options: options)
            for (index, size) in sizes.enumerated() {
                try writer.add(data: Data(repeating: UInt8(index + 65), count: size), as: "file-\(index)", modificationDate: TestSupport.date)
                XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: format), "\(format), item \(index)")
            }
            try writer.finishAdditions(progress: nil)
            XCTAssertEqual(writer.pendingInputBytes, 0)
            try writer.finish()
            let reader = try ArchiveReader.open(url: url)
            for (index, entry) in reader.entries.enumerated() {
                XCTAssertEqual(try reader.read(entry), Data(repeating: UInt8(index + 65), count: sizes[index]))
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
