import Foundation
import CryptoKit
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class BatchLargeFileTests: XCTestCase {
    private typealias B = BatchAdditionTestSupport
    private typealias S = AdditionProgressTestSupport

    func testBatchXZLongPoleEncodesBlocksConcurrentlyWithoutDrainingMediumItems() async throws {
        let root = try TestSupport.directory("batch-xz-concurrent-blocks")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 64 << 10
        // 16 MiB片四つの64 MiB項目と同じ形を、小さい片幅で検証する。
        let items = try inputs(root, sizes: [width / 2, width / 2, 4 * width + 7])
        for threads in [4, 16, 36] {
            try B.resetDates(items)
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let activity = Mutex((running: 0, peak: 0))
            let pending = Mutex<Int?>(nil)
            let task = Task.detached {
                try EntryCompressionConfiguration.$testingInputLimit.withValue(width) {
                    try LZMAWriterConfiguration.$testingPieceSize.withValue(width) {
                        try ZipWriter.$testingBeforeBatchBlocks.withValue({ index, count, _ in
                            if index == 2 { pending.withLock { $0 = count } }
                        }) {
                            try ZipWriter.$testingBatchXZEncoder.withValue({ bytes in
                                activity.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                                defer { activity.withLock { $0.running -= 1 } }
                                started.signal()
                                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                                return try LZMA2Compressor.encode(bytes)
                            }) {
                                let options = WriterOptions(compressionMethod: .xz, useCompressionHeuristic: false, compressionThreads: threads)
                                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("t\(threads)"), options: options)
                                try writer.add(items, events: { _ in
                                    XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .zip))
                                })
                                try writer.finish()
                            }
                        }
                    }
                }
            }
            defer { for _ in 0..<32 { release.signal() } }
            try await LZMA2ChunkPipelineTests.wait(started)
            try await LZMA2ChunkPipelineTests.wait(started)
            XCTAssertEqual(pending.withLock { $0 }, 2)
            XCTAssertGreaterThanOrEqual(activity.withLock { $0.peak }, 2)
            for _ in 0..<32 { release.signal() }
            try await task.value
            XCTAssertEqual(activity.withLock { $0.running }, 0)
        }
    }

    func testParallelPieceByteIdentityAgainstBranchAndItemAPI() throws {
        // ZIP の DOS timestamp を固定ハッシュ取得時の JST に揃える。
        let originalZone = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "Asia/Tokyo", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let originalZone { setenv("TZ", originalZone, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let root = try TestSupport.directory("batch-piece-branch-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [128 << 10, 128 << 10, (17 << 20) + 1])
        for item in items { XCTAssertEqual(chmod(item.sourceURL!.path, 0o644), 0) }
        for format: ArchiveFormat in [.zip, .sevenZip] {
            var expected: Data?
            for threads in [1, 4, 16, 36] {
                for batch in [false, true] {
                    try B.resetDates(items)
                    let output = root.appendingPathComponent("archive")
                    let options = WriterOptions(compressionMethod: .xz, sevenZipMethod: .bzip2,
                        bzip2Level: 1, useCompressionHeuristic: false, compressionThreads: threads)
                    let writer = try ArchiveWriter.create(url: output, format: format, options: options)
                    if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                    try writer.finish()
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertTrue(bytes == expected, "\(format), t=\(threads), batch=\(batch)") }
                    else {
                        expected = bytes
                        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        // 0a40b74 の一括・項目API、threads 1/4/16/36で取得した固定出力。
                        XCTAssertEqual(digest, format == .zip
                            ? "ca8bbf7a9cbee81d48cf74dee486e289a616291cb070fc236626a8dc261ae4b3"
                            : "bc1567e3e8d44be807cb3df02cce4eaf673ae76f18b95f52d1988aadaed9b2a8")
                    }
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }

    func testBatchXZPiecesMatchItemFramingWithAESAndExplicitLevel() throws {
        let root = try TestSupport.directory("batch-xz-piece-framing")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 64 << 10
        let items = try inputs(root, sizes: [width / 2, width / 2, 4 * width + 7, width / 2])
        try EntryCompressionConfiguration.$testingInputLimit.withValue(width) {
            try LZMAWriterConfiguration.$testingPieceSize.withValue(width) {
                for level in [nil, 0] as [Int?] {
                    for encrypted in [false, true] {
                        var expected: Data?
                        for threads in [1, 4, 16, 36] {
                            for batch in [false, true] {
                                try B.resetDates(items)
                                let output = root.appendingPathComponent("archive")
                                let options = WriterOptions(compressionMethod: .xz, lzmaLevel: level, useCompressionHeuristic: false,
                                    password: encrypted ? "xz-pieces" : nil, compressionThreads: threads)
                                let writer = try ArchiveWriter.create(url: output, format: .zip, options: options,
                                    zipSalt: { Data(repeating: 0x17, count: 16) }, lzmaChunkSize: width)
                                if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                                try writer.finish()
                                let bytes = try Data(contentsOf: output)
                                if let expected { XCTAssertTrue(bytes == expected, "level=\(String(describing: level)), AES=\(encrypted), t=\(threads), batch=\(batch)") }
                                else { expected = bytes }
                                try FileManager.default.removeItem(at: output)
                            }
                        }
                    }
                }
            }
        }
    }

    func testBatchXZFourIncompressiblePiecesMatchItemAPIWithFullMediumWindow() throws {
        let root = try TestSupport.directory("batch-xz-four-random-pieces")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 1 << 20
        let items = try (0..<25).map { index in
            let source = root.appendingPathComponent("source-\(index)")
            try TestCorpus.random(index == 24 ? 4 * width : width / 2).write(to: source)
            return ArchiveAddition(path: "file-\(index)", source: .contents(of: source))
        }
        try EntryCompressionConfiguration.$testingInputLimit.withValue(width) {
            try LZMAWriterConfiguration.$testingPieceSize.withValue(width) {
                var expected: Data?
                for (batch, threads) in [(false, 1), (true, 4), (true, 16), (true, 36)] {
                    try B.resetDates(items)
                    let output = root.appendingPathComponent("archive")
                    let writer = try ArchiveWriter.create(url: output, options: .init(compressionMethod: .xz,
                        useCompressionHeuristic: false, compressionThreads: threads))
                    if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                    try writer.finish()
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertTrue(bytes == expected, "t=\(threads)") } else { expected = bytes }
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }

    func testBatchXZPieceFailuresKeepIndexAndRecheckSourceAfterEarlierCallback() throws {
        let root = try TestSupport.directory("batch-xz-piece-failures")
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 64 << 10
        for failure in ["worker", "earlier", "replace"] {
            let items = try inputs(root, sizes: [width / 2, width / 2, 4 * width + 7])
            var finished: [Int] = []
            try EntryCompressionConfiguration.$testingInputLimit.withValue(width) {
                try LZMAWriterConfiguration.$testingPieceSize.withValue(width) {
                    try ZipWriter.$testingBatchXZEncoder.withValue({ bytes in
                        if failure == "worker" { throw WriterError.compression(-73) }
                        return try LZMA2Compressor.encode(bytes)
                    }) {
                        try FileJob.$testingDuringWorkerRead.withValue({ index, _ in
                            if failure == "earlier", index == 1 { throw WriterError.compression(-74) }
                            if failure == "earlier", index == 2 { throw WriterError.compression(-75) }
                        }) {
                            let writer = try ArchiveWriter.create(url: root.appendingPathComponent(failure),
                                options: .init(compressionMethod: .xz, useCompressionHeuristic: false, compressionThreads: 4))
                            XCTAssertThrowsError(try writer.add(items, events: { event in
                                if case let .didFinish(index) = event {
                                    finished.append(index)
                                    if failure == "replace", index == 0 {
                                        try Data(repeating: 3, count: 4 * width + 7).write(to: items[2].sourceURL!, options: .atomic)
                                    }
                                }
                            })) { error in
                                let actual = error as? ArchiveAdditionError
                                XCTAssertEqual(actual?.index, failure == "earlier" ? 1 : 2)
                                XCTAssertEqual(actual?.underlying as? WriterError, failure == "replace"
                                    ? .sourceChanged(items[2].sourceURL!.path) : .compression(failure == "earlier" ? -74 : -73))
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(finished, failure == "earlier" ? [0] : [0, 1])
        }
    }

    private func inputs(_ root: URL, sizes: [Int]) throws -> [ArchiveAddition] {
        try sizes.enumerated().map { index, size in
            let file = root.appendingPathComponent("input-\(index)")
            let seed = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 13 + index) })
            var data = Data(); data.reserveCapacity(size)
            while data.count < size { data.append(seed.prefix(min(seed.count, size - data.count))) }
            try data.write(to: file)
            try S.timestamp(file)
            return .init(path: "file-\(index)", source: .contents(of: file))
        }
    }

    func testMixedSizesMatchItemBytesAllZIPMethodsAndThreads() throws {
        let root = try TestSupport.directory("batch-large-matrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [13, S.mib - 1, S.mib, S.mib + 1, 2 * S.mib + 3, 3 * S.mib, 17 * S.mib])
        for method: CompressionMethod in [.stored, .deflate, .bzip2, .lzma, .xz, .zstd, .ppmd] {
            for threads in [1, 4, 10, 36] {
                let options = WriterOptions(compressionMethod: method, useCompressionHeuristic: false, compressionThreads: threads)
                var expected: Data?
                for observed in [nil, false, true] as [Bool?] {
                    try B.resetDates(items)
                    let output = root.appendingPathComponent("archive")
                    let writer = try ArchiveWriter.create(url: output, options: options)
                    if let observed { try writer.add(items, events: observed ? { _ in } : nil) }
                    else { try B.singles(writer, items) }
                    try writer.finish()
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertTrue(bytes == expected, "\(method) threads=\(threads) observed=\(String(describing: observed))") }
                    else { expected = bytes }
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }

    func testLargeStoredHeuristicMatchesItemAcrossEntryWindows() throws {
        let root = try TestSupport.directory("batch-large-heuristic")
        defer { try? FileManager.default.removeItem(at: root) }
        var items = try inputs(root, sizes: [65536, 2 * S.mib + 1, 65536])
        items[1].path += ".png"
        for method: CompressionMethod in [.deflate, .bzip2, .lzma, .xz, .zstd, .ppmd] {
            var expected: Data?
            for batch in [false, true] {
                try B.resetDates(items)
                let output = root.appendingPathComponent("archive")
                let writer = try ArchiveWriter.create(url: output, options: .init(compressionMethod: method, compressionThreads: 4))
                if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                try writer.finish()
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertTrue(bytes == expected, "\(method)") } else { expected = bytes }
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testLargeStreamsAndXZBlocksKeepEntryWindowEventsAndMemoryBound() throws {
        let root = try TestSupport.directory("batch-large-stream-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, S.mib - 1, 17 * S.mib, S.mib - 1])
        for method: CompressionMethod in [.lzma, .xz, .zstd, .ppmd] {
            let options = WriterOptions(compressionMethod: method, compressionThreads: 4)
            guard EntryCompressionConfiguration(options: options).threads > 1 else { continue }
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(method)"), options: options)
            let probe = Mutex(false), spools = Mutex(0)
            var finished: [Int] = [], nextProgress = 0
            var sessions: [Int: S.Session] = [:]
            try ZipWriter.$testingBeforeBatchBlocks.withValue({ index, count, _ in
                if index == 2 {
                    XCTAssertGreaterThan(count, 0)
                    probe.withLock { $0 = true }
                }
            }) {
                try ScratchFile.$testingCreated.withValue({ _ in spools.withLock { $0 += 1 } }) {
                    try writer.add(items, events: { event in
                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .zip))
                        switch event {
                        case .willStart(3): XCTAssertFalse(finished.contains(2))
                        case let .progress(index, progress):
                            XCTAssertEqual(index, nextProgress)
                            if sessions[index] == nil { sessions[index] = S.Session() }
                            sessions[index]!.record(progress)
                        case let .didFinish(index):
                            XCTAssertEqual(index, nextProgress)
                            nextProgress += 1; finished.append(index)
                        default: break
                        }
                    })
                }
            }
            XCTAssertTrue(probe.withLock { $0 })
            // XZは共有窓の片を直接emitし、他の単一streamはdisk spoolを通る。
            if method == .xz { XCTAssertEqual(spools.withLock { $0 }, 0) }
            else { XCTAssertGreaterThan(spools.withLock { $0 }, 0) }
            XCTAssertEqual(finished, Array(items.indices))
            for index in items.indices { sessions[index]!.check(total: try ArchiveWriter.inputByteCount(items[index].sourceURL!)) }
            XCTAssertEqual(sessions[2]!.updates.map(\.completedBytes), [0, 4 << 20, 8 << 20, 12 << 20, 16 << 20, 17 << 20])
            try writer.finish()
        }
    }

    func testLargeBlocksKeepEarlierWorkWindowEventsAndMeter() throws {
        let root = try TestSupport.directory("batch-large-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, S.mib - 1, 17 * S.mib, 2 * S.mib + 1])
        for method: CompressionMethod in [.stored, .deflate] {
            let options = WriterOptions(compressionMethod: method, compressionThreads: 10)
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(method).zip"), options: options)
            let probes = Mutex(Set<Int>())
            let descriptors = Mutex((current: 0, maximum: 0))
            let caller = pthread_self()
            var finished: [Int] = [], nextProgress = 0
            var sessions: [Int: S.Session] = [:]
            let total = items.reduce(UInt64(0)) { $0 + (try! ArchiveWriter.inputByteCount($1.sourceURL!)) }
            let meter = CommitProgressMeter(total: total, progress: nil)
            try ZipWriter.$testingBeforeBatchBlocks.withValue({ index, count, bytes in
                if index == 2 {
                    XCTAssertEqual(count, 2)
                    XCTAssertEqual(bytes, UInt64(2 * (S.mib - 1)))
                    probes.withLock { _ = $0.insert(index) }
                } else if index == 3 {
                    XCTAssertGreaterThan(count, 0)
                    probes.withLock { _ = $0.insert(index) }
                }
            }) {
                try FileJob.$testingDescriptorChange.withValue({ delta in
                    descriptors.withLock { $0.current += delta; $0.maximum = max($0.maximum, $0.current) }
                }) {
                    try writer.add(items, expected: nil, meter: meter, events: { event in
                        XCTAssertNotEqual(pthread_equal(caller, pthread_self()), 0)
                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .zip))
                        switch event {
                        case let .willStart(index): XCTAssertLessThanOrEqual(index - finished.count + 1, 10)
                        case let .progress(index, progress):
                            XCTAssertEqual(index, nextProgress)
                            if sessions[index] == nil { sessions[index] = S.Session() }
                            sessions[index]!.record(progress)
                        case let .didFinish(index):
                            XCTAssertEqual(index, nextProgress)
                            finished.append(index); nextProgress += 1
                        }
                    })
                }
            }
            XCTAssertEqual(probes.withLock { $0 }, [2, 3])
            XCTAssertEqual(finished, Array(items.indices))
            XCTAssertEqual(meter.completed, total)
            XCTAssertEqual(descriptors.withLock { $0.current }, 0)
            XCTAssertLessThanOrEqual(descriptors.withLock { $0.maximum }, 4)
            for index in items.indices { sessions[index]!.check(total: try ArchiveWriter.inputByteCount(items[index].sourceURL!)) }
            XCTAssertEqual(writer.pendingInputBytes, 0)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip), 10 << 20)
            try writer.finish()
        }
    }

    func testLargeSourceFailurePrefersEarlierWorkerFailure() throws {
        let root = try TestSupport.directory("batch-large-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, S.mib - 1, 3 * S.mib])
        for earlierFailure in [nil, "read", "worker"] as [String?] {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(earlierFailure ?? "none").zip"), format: .zip,
                options: .init(compressionThreads: 10), deflateEncoder: { block, level in
                    if earlierFailure == "worker", block.input.first == 1 { throw WriterError.compression(-71) }
                    return try DeflateBlock.encode(block, level: level)
                }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
            let reads = Mutex(0)
            var finished: [Int] = []
            try FileJob.$testingDuringWorkerRead.withValue({ index, _ in
                if index == 1, earlierFailure == "read" { throw WriterError.io(operation: "earlier read", code: EIO) }
                guard index == 2 else { return }
                if reads.withLock({ $0 += 1; return $0 }) == 6 { throw WriterError.io(operation: "injected read", code: EIO) }
            }) {
                XCTAssertThrowsError(try writer.add(items, events: { if case let .didFinish(index) = $0 { finished.append(index) } })) {
                    let failure = $0 as? ArchiveAdditionError
                    let index = earlierFailure == nil ? 2 : 1
                    XCTAssertEqual(failure?.index, index)
                    XCTAssertEqual(failure?.sourceURL, items[index].sourceURL)
                    XCTAssertEqual(failure?.underlying as? WriterError, earlierFailure == "worker" ? .compression(-71)
                        : .io(operation: earlierFailure == "read" ? "earlier read" : "injected read", code: EIO))
                }
            }
            XCTAssertEqual(finished, earlierFailure == nil ? [0, 1] : [0])
        }
    }

    func testLargeWorkerFailureHasItsIndex() throws {
        let root = try TestSupport.directory("batch-large-worker-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, S.mib - 1, 3 * S.mib])
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive"), format: .zip,
            options: .init(compressionThreads: 10), deflateEncoder: { block, level in
                if block.input.first == 2 { throw WriterError.compression(-72) }
                return try DeflateBlock.encode(block, level: level)
            }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        var finished: [Int] = []
        XCTAssertThrowsError(try writer.add(items, events: { if case let .didFinish(index) = $0 { finished.append(index) } })) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 2)
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .compression(-72))
        }
        XCTAssertEqual(finished, [0, 1])
    }

    func testLargeCallbackFailuresAreUnwrapped() throws {
        let root = try TestSupport.directory("batch-large-callback")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, 17 * S.mib])
        for phase in ["start", "progress", "finish"] {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent(phase), options: .init(compressionThreads: 4))
            let opened = Mutex(Set<Int>()), descriptors = Mutex(0)
            try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in opened.withLock { _ = $0.insert(index) } }) {
                try FileJob.$testingDescriptorChange.withValue({ delta in descriptors.withLock { $0 += delta } }) {
                    XCTAssertThrowsError(try writer.add(items, events: { event in
                        switch event {
                        case .willStart(1) where phase == "start", .didFinish(1) where phase == "finish": throw S.Failure.callback
                        case let .progress(1, progress) where phase == "progress" && progress.completedBytes >= 4 << 20: throw S.Failure.callback
                        default: break
                        }
                    })) { XCTAssertEqual($0 as? S.Failure, .callback) }
                }
            }
            if phase == "start" { XCTAssertFalse(opened.withLock { $0.contains(1) }) }
            XCTAssertEqual(descriptors.withLock { $0 }, 0)
        }
    }

    func testLargeMutationIsSourceChanged() throws {
        let root = try TestSupport.directory("batch-large-mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        for method: CompressionMethod in [.stored, .deflate] {
            for mutation in ["grow", "shrink", "replace"] {
                let items = try inputs(root, sizes: [S.mib - 1, 3 * S.mib])
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(method)-\(mutation)"), options: .init(compressionMethod: method, compressionThreads: 10))
                let changed = Mutex(false)
                var finished: [Int] = []
                try FileJob.$testingDuringWorkerRead.withValue({ index, url in
                    guard index == 1, changed.withLock({ if $0 { return false }; $0 = true; return true }) else { return }
                    if mutation == "replace" { try Data(repeating: 3, count: 3 * S.mib).write(to: url, options: .atomic) }
                    else {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        if mutation == "grow" { try handle.seekToEnd(); try handle.write(contentsOf: Data([1])) }
                        else { try handle.truncate(atOffset: 11) }
                    }
                }) {
                    XCTAssertThrowsError(try writer.add(items, events: { if case let .didFinish(index) = $0 { finished.append(index) } })) {
                        XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 1)
                        XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError,
                                       .sourceChanged(mutation == "grow" ? items[1].path : items[1].sourceURL!.path))
                    }
                }
                XCTAssertEqual(finished, [0])
            }
        }
    }

    func testCancellationDuringLargeReadAndProgressClosesDescriptors() async throws {
        let root = try TestSupport.directory("batch-large-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, 17 * S.mib])
        for phase in ["read", "progress"] {
            try await Task.detached {
                let options = WriterOptions(compressionThreads: 4)
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent(phase), options: options)
                let descriptors = Mutex(0), reads = Mutex(0)
                var finished: [Int] = []
                let start = Date()
                try FileJob.$testingDescriptorChange.withValue({ delta in descriptors.withLock { $0 += delta } }) {
                    try FileJob.$testingDuringWorkerRead.withValue({ index, _ in
                        guard index == 1, phase == "read" else { return }
                        if reads.withLock({ $0 += 1; return $0 }) == 18 { withUnsafeCurrentTask { $0?.cancel() } }
                    }) {
                        XCTAssertThrowsError(try writer.add(items, events: {
                            if case let .progress(index, progress) = $0, index == 1, progress.completedBytes >= 4 << 20, phase == "progress" {
                                withUnsafeCurrentTask { $0?.cancel() }
                            }
                            if case let .didFinish(index) = $0 { finished.append(index) }
                        })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
                    }
                }
                XCTAssertLessThan(Date().timeIntervalSince(start), 2)
                XCTAssertEqual(descriptors.withLock { $0 }, 0)
                XCTAssertFalse(finished.contains(1))
            }.value
        }
    }

    func testCancellationDuringLargeStreamWorkerClosesDescriptors() async throws {
        let root = try TestSupport.directory("batch-large-stream-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root, sizes: [S.mib - 1, S.mib - 1, 17 * S.mib])
        for method: CompressionMethod in [.lzma, .xz, .zstd, .ppmd] {
            let options = WriterOptions(compressionMethod: method, compressionThreads: 4)
            guard EntryCompressionConfiguration(options: options).threads > 1 else { continue }
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let descriptors = Mutex(0), firstRead = Mutex(true)
            let task = Task.detached {
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(method)"), options: options)
                try FileJob.$testingDescriptorChange.withValue({ delta in descriptors.withLock { $0 += delta } }) {
                    try FileJob.$testingDuringWorkerRead.withValue({ index, _ in
                        if index == 2, firstRead.withLock({ if !$0 { return false }; $0 = false; return true }) {
                            entered.signal()
                            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                        }
                    }) { try writer.add(items, events: nil) }
                }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            let start = Date()
            task.cancel(); release.signal()
            do { try await task.value; XCTFail("取消しが必要") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            XCTAssertEqual(descriptors.withLock { $0 }, 0)
        }
    }
}
