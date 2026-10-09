import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class ReviewFixSourceLifetimeTests: XCTestCase {
    private let payload = Data(repeating: 0x61, count: (17 << 20) + 7)

    private func source(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("source")
        try payload.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try AdditionProgressTestSupport.timestamp(url)
        return url
    }

    private func options(_ method: SevenZipCompressionMethod, threads: Int) -> WriterOptions {
        .init(sevenZipMethod: method, bzip2Level: 1, ppmdMemoryMiB: 1, lzmaLevel: 0, compressionThreads: threads)
    }

    private func checkWriter(batch: Bool) throws {
        let root = try TestSupport.directory("review-source-\(batch)")
        defer { try? FileManager.default.removeItem(at: root) }
        for method: SevenZipCompressionMethod in [.lzma, .ppmd, .bzip2] {
            let input = try source(root)
            let baseline = root.appendingPathComponent(UUID().uuidString)
            let old = try ArchiveWriter.create(url: baseline, format: .sevenZip, options: options(method, threads: 1))
            try old.add(data: Data([1]), as: "prior", modificationDate: TestSupport.date)
            // mainと同じ同期readの入口を基準にする。
            try old.add(contentsOf: input, as: "large", read: { try FileRead.readChunk($0.fileDescriptor, upTo: $1) })
            try old.finish()
            let expected = try Data(contentsOf: baseline)
            for rewrite in [false, true] {
                let input = try source(root), output = root.appendingPathComponent(UUID().uuidString)
                let writer = try ArchiveWriter.create(url: output, format: .sevenZip, options: options(method, threads: 4))
                try writer.add(data: Data([1]), as: "prior", modificationDate: TestSupport.date)
                if batch { try writer.add([.init(path: "large", source: .contents(of: input))], events: nil) }
                else { try writer.add(contentsOf: input, as: "large") }
                if rewrite { try Data([9]).write(to: input) }
                else { try FileManager.default.removeItem(at: input) }
                try writer.finishAdditions(progress: nil)
                try writer.finish()
                XCTAssertEqual(try Data(contentsOf: output), expected, "\(method), rewrite=\(rewrite)")
                try TestSupport.assertKaitoKitRoundTrip(output, expected: [
                    .init(name: "prior", data: Data([1])), .init(name: "large", data: payload)
                ])
            }
        }
    }

    func testPerItemReadsLargeSourcesBeforeReturning() throws { try checkWriter(batch: false) }
    func testBatchReadsLargeSourcesBeforeReturning() throws { try checkWriter(batch: true) }

    func testUpdaterAndRecursiveAddsOwnLargeSourceBytes() throws {
        let root = try TestSupport.directory("review-updater-source")
        defer { try? FileManager.default.removeItem(at: root) }
        for batch in [false, true] {
            let input = try source(root), base = root.appendingPathComponent(UUID().uuidString)
            let writer = try ArchiveWriter.create(url: base, format: .sevenZip, options: options(.lzma, threads: 1))
            try writer.add(data: Data([1]), as: "prior", modificationDate: TestSupport.date)
            try writer.finish()
            let output = root.appendingPathComponent(UUID().uuidString)
            let updater = try SevenZipUpdater.open(url: base, output: output, options: options(.lzma, threads: 4))
            if batch { try updater.add([.init(path: "large", source: .contents(of: input))], events: nil) }
            else { try updater.add(contentsOf: input, as: "large") }
            try FileManager.default.removeItem(at: input)
            try updater.commit()
            try TestSupport.assertKaitoKitRoundTrip(output, expected: [
                .init(name: "prior", data: Data([1])), .init(name: "large", data: payload)
            ])
        }
        let tree = try TestSupport.work(in: root), input = try source(tree)
        let output = root.appendingPathComponent("recursive.7z")
        let writer = try ArchiveWriter.create(url: output, format: .sevenZip, options: options(.lzma, threads: 4))
        try writer.add(contentsOf: tree, as: "tree")
        try FileManager.default.removeItem(at: input)
        try writer.finish()
        try TestSupport.assertKaitoKitRoundTrip(output, expected: [
            .init(name: "tree/", kind: .directory, permissions: 0o755, date: nil),
            .init(name: "tree/source", data: payload)
        ])
    }
}

final class ReviewFixAttributionTests: XCTestCase {
    private func inputs(_ root: URL, sizes: [Int]) throws -> [ArchiveAddition] {
        try sizes.enumerated().map { index, size in
            let source = root.appendingPathComponent("source-\(index)")
            try Data(repeating: UInt8(index + 1), count: size).write(to: source)
            return .init(path: "file-\(index)", source: .contents(of: source))
        }
    }

    func testEarlyZIPSetupFailureRetainsIndexAndEarlierFailureWins() throws {
        let root = try TestSupport.directory("review-early-setup")
        defer { try? FileManager.default.removeItem(at: root) }
        try EntryCompressionConfiguration.$testingInputLimit.withValue(64 << 10) {
            for method: CompressionMethod in [.lzma, .ppmd, .zstd] {
                for largeIndex in [0, 2, 5] {
                    for earlierFailure in [false, true] where !earlierFailure || largeIndex > 0 {
                        let items = try inputs(root, sizes: (0..<6).map { $0 == largeIndex ? 128 << 10 : 32 << 10 })
                        let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString),
                            options: .init(compressionMethod: method, ppmdMemoryMiB: 1, lzmaLevel: 0,
                                useCompressionHeuristic: false, compressionThreads: 4))
                        var finished: [Int] = []
                        try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in
                            if earlierFailure && index == 0 { throw WriterError.compression(-91) }
                        }) {
                            try ScratchFile.$testingFreeSpaceReserve.withValue(.max) {
                                XCTAssertThrowsError(try writer.add(items, events: {
                                    if case let .didFinish(index) = $0 { finished.append(index) }
                                })) {
                                    let failure = $0 as? ArchiveAdditionError
                                    XCTAssertEqual(failure?.index, earlierFailure ? 0 : largeIndex, "\(method), \(largeIndex)")
                                    XCTAssertEqual(failure?.sourceURL, items[earlierFailure ? 0 : largeIndex].sourceURL)
                                    XCTAssertEqual(failure?.underlying as? WriterError, earlierFailure
                                        ? .compression(-91) : .io(operation: "free space", code: ENOSPC))
                                }
                            }
                        }
                        XCTAssertEqual(finished, Array(0..<(earlierFailure ? 0 : largeIndex)))
                    }
                }
            }
        }
    }

    func testEarlierBatchReadFailureBeatsLargeReadFailureBehindPerItemHead() throws {
        let root = try TestSupport.directory("review-prior-head")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 64 << 10
        try EntryCompressionConfiguration.$testingInputLimit.withValue(width) {
            try LZMAWriterConfiguration.$testingPieceSize.withValue(width) {
                for method: CompressionMethod in [.deflate, .xz] {
                    let items = try inputs(root, sizes: [width / 2, 2 * width + 7])
                    let output = root.appendingPathComponent(UUID().uuidString)
                    FileManager.default.createFile(atPath: output.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: output)
                    defer { try? handle.close() }
                    let writer = ZipWriter(output: handle, url: output,
                        options: .init(compressionMethod: method, useCompressionHeuristic: false, compressionThreads: 8),
                        deflateBlockSize: width, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
                    let prior = Data(repeating: 0x61, count: width / 2)
                    var offset = 0
                    try writer.add(name: "prior", mode: FileMode.regular | 0o644, size: UInt64(prior.count),
                        date: TestSupport.date, atime: nil, owners: nil) { count in
                        let end = min(prior.count, offset + count)
                        defer { offset = end }
                        return prior.subdata(in: offset..<end)
                    }
                    try ZipWriter.$testingBeforeBatchBlocks.withValue({ _, count, _ in XCTAssertGreaterThanOrEqual(count, 2) }) {
                        try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in throw WriterError.compression(index == 0 ? -92 : -93) }) {
                            // GCDへ渡すhookはFileJob生成時に取り込まれる。
                            let failedJobs = try items.enumerated().map { index, item in
                                var info = stat()
                                guard lstat(item.sourceURL!.path, &info) == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
                                return FileJob(index: index, addition: item, path: Array(item.sourceURL!.path.utf8CString),
                                    expected: DiskSignature(info), size: Int(info.st_size), deflate: method == .deflate,
                                    limiter: SourcePrefetchLimiter(threads: 8))
                            }
                            let first = AdditionAttribution(index: 0, addition: items[0])
                            try writer.submit(failedJobs[0], method: method, attribution: first,
                                weight: UInt64(failedJobs[0].size), emit: writer.emitDeflate)
                            let entry = try writer.makeEntry(name: items[1].path, mode: FileMode.regular | 0o644,
                                size: UInt64(failedJobs[1].size), date: TestSupport.date, atime: nil, owners: nil)
                            XCTAssertThrowsError(try writer.submitLarge(entry, file: failedJobs[1],
                                attribution: .init(index: 1, addition: items[1]), emit: writer.emitDeflate)) {
                                XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 0, "\(method)")
                                XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .compression(-92))
                            }
                        }
                    }
                }
            }
        }
    }

    func testPreviousPerItemFailureIsDrainedBeforeOpeningBatchSource() throws {
        let root = try TestSupport.directory("review-prior-drain")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [32768, 131079]), opened = Mutex(0)
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive.zip"), format: .zip,
            options: .init(useCompressionHeuristic: false, compressionThreads: 8), deflateBlockSize: 65536,
            deflateEncoder: { _, _ in throw WriterError.compression(-95) }, lzmaChunkSize: 65536)
        try writer.add(data: Data(repeating: 0x61, count: 32768), as: "prior", modificationDate: TestSupport.date)
        try FileJob.$testingBeforeWorkerOpen.withValue({ _, _ in opened.withLock { $0 += 1 } }) {
            XCTAssertThrowsError(try writer.add(items, events: nil)) { XCTAssertEqual($0 as? WriterError, .compression(-95)) }
        }
        XCTAssertEqual(opened.withLock { $0 }, 0)
    }

    func testSevenZipWorkerFailureIsRawAfterBatchReturn() throws {
        let root = try TestSupport.directory("review-seven-attribution")
        defer { try? FileManager.default.removeItem(at: root) }
        for solid in [false, true] {
            for later in ["finishAdditions", "finish", "add"] {
                let items = try inputs(root, sizes: [4096])
                let failed = DispatchSemaphore(value: 0)
                try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                    if name == "file-0" { failed.signal(); throw WriterError.compression(-94) }
                }) {
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: .sevenZip,
                        options: .init(sevenZipMethod: .lzma,
                            sevenZipSolid: solid ? .on(blockSize: 4096, filesPerBlock: nil) : .off,
                            lzmaLevel: 0, compressionThreads: 4))
                    try writer.add(items, events: nil)
                    XCTAssertEqual(failed.wait(timeout: .now() + 5), .success)
                    XCTAssertThrowsError(try {
                        if later == "finishAdditions" { try writer.finishAdditions(progress: nil) }
                        else if later == "finish" { try writer.finish() }
                        else {
                            // 窓の先頭が出力されるまで後続の項目を追加する。
                            for index in 0..<16 { try writer.add(data: Data(repeating: 1, count: 4096), as: "later-\(index)") }
                        }
                    }()) { XCTAssertEqual($0 as? WriterError, .compression(-94), "solid=\(solid), \(later): \($0)") }
                }
            }
        }
    }

    func testSevenZipOpenSolidScratchDoesNotRetainBatchAttribution() throws {
        let root = try TestSupport.directory("review-seven-scratch-attribution")
        defer { try? FileManager.default.removeItem(at: root) }
        for later in ["finishAdditions", "finish", "add"] {
            let items = try inputs(root, sizes: [4096]), output = root.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            let options = WriterOptions(sevenZipMethod: .lzma, sevenZipSolid: .on(blockSize: 8192, filesPerBlock: nil),
                lzmaLevel: 0, compressionThreads: 1)
            let seven = try SevenZipWriter(output: handle, url: output, options: options)
            let writer = ArchiveWriter(output: handle, url: output, format: .sevenZip, options: options, sevenZipWriter: seven)
            try writer.add(items, events: nil)
            // FileHandleは開いたまま、出力fdだけを読取専用にしてwriteを失敗させる。
            let readOnly = Darwin.open(output.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(readOnly, 0)
            XCTAssertEqual(dup2(readOnly, handle.fileDescriptor), handle.fileDescriptor)
            Darwin.close(readOnly)
            XCTAssertThrowsError(try {
                if later == "finishAdditions" { try writer.finishAdditions(progress: nil) }
                else if later == "finish" { try writer.finish() }
                else { try writer.add(data: Data(repeating: 1, count: 8192), as: "later") }
            }()) {
                XCTAssertFalse($0 is ArchiveAdditionError, "\(later): \($0)")
                XCTAssertEqual(($0 as NSError).domain, NSCocoaErrorDomain)
            }
        }
    }
}

final class ReviewFixZstdBudgetTests: XCTestCase {
    func testSpeedPriorityFallsBackToSingleFrameForItemAndBatch() throws {
        let root = try TestSupport.directory("review-zstd-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x61, count: (5 << 20) + 7), source = root.appendingPathComponent("source")
        try payload.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        try AdditionProgressTestSupport.timestamp(source)
        var options = WriterOptions(compressionMethod: .zstd, prefersSpeed: true, useCompressionHeuristic: false)
        let single = try ZstdWriterConfiguration(options: options, streaming: true)
        let parallel = try ZstdWriterConfiguration(options: options)
        XCTAssertGreaterThan(parallel.memoryPerThread, single.memoryPerThread)
        for budget in [single.memoryPerThread, parallel.memoryPerThread - 1] {
            options.memoryLimit = budget
            XCTAssertTrue(try ZstdWriterConfiguration.zip(options: options).streaming)
            var expected: Data?
            for threads in [1, 4, 16] {
                options.compressionThreads = threads
                for batch in [false, true] {
                    let output = root.appendingPathComponent(UUID().uuidString)
                    let writer = try ArchiveWriter.create(url: output, options: options)
                    if batch { try writer.add([.init(path: "large", source: .contents(of: source))], events: nil) }
                    else { try writer.add(contentsOf: source, as: "large") }
                    try writer.finish()
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                    let zip = ZipBytes(data: bytes)
                    let cd = ZipBytes(data: try XCTUnwrap(ZipAdditionalCompressionSupport.centralRecords(output).first))
                    let start = 30 + Int(zip.u16(26)) + Int(zip.u16(28))
                    let frame = bytes.subdata(in: start..<(start + Int(cd.u32(20))))
                    XCTAssertEqual(try ZstdWriterTestSupport.frames(frame).map(\.contentSize), [UInt64(payload.count)])
                    try TestSupport.assertKaitoKitRoundTrip(output, expected: [.init(name: "large", data: payload)])
                }
            }
        }
        options.memoryLimit = parallel.memoryPerThread
        XCTAssertFalse(try ZstdWriterConfiguration.zip(options: options).streaming)
    }
}
