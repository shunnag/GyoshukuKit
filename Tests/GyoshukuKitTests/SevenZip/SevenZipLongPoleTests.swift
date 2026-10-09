import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class SevenZipLongPoleTests: XCTestCase {
    private static let methods: [SevenZipCompressionMethod] = [.lzma, .ppmd, .bzip2, .lzma2, .deflate, .copy]
    private static let limit = 64 << 10

    private static func options(_ method: SevenZipCompressionMethod, solid: Bool, filter: SevenZipFilterMode,
                                encryption: Int = 0, threads: Int = 4) -> WriterOptions {
        WriterOptions(sevenZipMethod: method, sevenZipSolid: solid ? .on(blockSize: UInt64(limit), filesPerBlock: 1) : .off,
            sevenZipFilter: filter, bzip2Level: 1, ppmdMemoryMiB: 1, lzmaLevel: 0,
            password: encryption == 0 ? nil : "long-pole", encryptsSevenZipHeaders: encryption == 2,
            compressionThreads: threads)
    }

    private static func payload(_ size: Int) -> Data {
        let pattern = Data((0..<1024).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 3)) })
        var data = Data()
        while data.count < size { data.append(pattern.prefix(min(pattern.count, size - data.count))) }
        return data
    }

    func testNonSolidBatchBzip2LongPoleRunsSpliceChunksConcurrentlyAfterFullMediumWindow() async throws {
        let root = try TestSupport.directory("7z-batch-bzip2-concurrent-long-pole")
        defer { try? FileManager.default.removeItem(at: root) }
        let medium = Self.payload(Self.limit / 2), large = Self.payload(2 << 20)
        let items = try (0..<5).map { index in
            let file = root.appendingPathComponent("source-\(index)")
            try (index == 4 ? large : medium).write(to: file)
            try AdditionProgressTestSupport.timestamp(file)
            return ArchiveAddition(path: index == 4 ? "long" : "medium-\(index)", source: .contents(of: file))
        }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let activity = Mutex((running: 0, peak: 0))
        let reservation = Mutex<(Int, Int)?>(nil)
        let normalWindow = Mutex(0)
        let task = Task.detached {
            try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                try SevenZipWriter.$testingWillSubmit.withValue({ name, count, streamed, inner in
                    if name == "long" {
                        XCTAssertTrue(streamed)
                        reservation.withLock { $0 = (count, inner) }
                    } else {
                        normalWindow.withLock { $0 = max($0, count + 1) }
                    }
                }) {
                    try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                        activity.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                        defer { activity.withLock { $0.running -= 1 } }
                        started.signal()
                        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                        var output = Data()
                        try Bzip2StreamEncoder(level: level).write(bytes, finish: true) { output.append($0) }
                        return output
                    }) {
                        let options = Self.options(.bzip2, solid: false, filter: .none, threads: 4)
                        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive"), format: .sevenZip, options: options)
                        // 通常窓が満杯のときの従来splice予約を検証する。早期投入はBatchAdditionLongPoleTestsで検証。
                        try ArchiveWriter.$testingDisablesEarlyLongPoles.withValue(true) {
                            try writer.add(items, events: { _ in
                                XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .sevenZip))
                            })
                        }
                        try writer.finish()
                    }
                }
            }
        }
        defer { for _ in 0..<64 { release.signal() } }
        try await LZMA2ChunkPipelineTests.wait(started)
        try await LZMA2ChunkPipelineTests.wait(started)
        let observed = try XCTUnwrap(reservation.withLock { $0 })
        XCTAssertEqual(normalWindow.withLock { $0 }, 4)
        XCTAssertEqual(observed.0, 1)
        XCTAssertEqual(observed.1, 3)
        XCTAssertGreaterThanOrEqual(activity.withLock { $0.peak }, 2)
        for _ in 0..<64 { release.signal() }
        try await task.value
        XCTAssertEqual(activity.withLock { $0.running }, 0)
    }

    func testOldDrainByteIdentityAllMethodsFiltersAESAndThreadCounts() throws {
        let root = try TestSupport.directory("7z-long-pole-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let medium = Self.payload(Self.limit), large = Self.payload(3 * Self.limit + 7)
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for method in Self.methods {
                for solid in [false, true] {
                    for filter: SevenZipFilterMode in [.none, .delta(distance: 4), .bcjX86] {
                        for encryption in 0...2 {
                            var expected: Data?
                            // old=trueでは変更前の巨大folder/itemのdrain経路を強制する。
                            for (old, threads) in [(true, 4), (false, 1), (false, 4), (false, 10), (false, 36)] {
                                let iv = Mutex<UInt8>(0)
                                let output = root.appendingPathComponent(UUID().uuidString)
                                let options = Self.options(method, solid: solid, filter: filter, encryption: encryption, threads: threads)
                                try SevenZipWriter.$testingOldDrain.withValue(old) {
                                    try SevenZipAESEncryptor.$testingIV.withValue({
                                        iv.withLock { $0 &+= 1; return Data(repeating: $0, count: 16) }
                                    }) {
                                        let writer = try ArchiveWriter.create(url: output, format: .sevenZip, options: options,
                                            lzmaChunkSize: 16 << 10)
                                        for index in 0..<3 {
                                            try writer.add(data: medium, as: "medium-\(index)", modificationDate: TestSupport.date)
                                        }
                                        try writer.add(data: large, as: "long", modificationDate: TestSupport.date)
                                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .sevenZip))
                                        let pending = writer.pendingInputBytes
                                        var updates: [ArchiveUpdater.CommitProgress] = []
                                        try writer.finishAdditions(progress: { updates.append($0) })
                                        XCTAssertEqual(writer.pendingInputBytes, 0)
                                        XCTAssertEqual(updates.last?.completedBytes, pending)
                                        XCTAssertEqual(updates.last?.totalBytes, pending)
                                        try writer.finish()
                                    }
                                }
                                let bytes = try Data(contentsOf: output)
                                if let expected {
                                    XCTAssertEqual(bytes, expected, "\(method), solid=\(solid), \(filter), AES=\(encryption), t=\(threads)")
                                } else { expected = bytes }
                                try FileManager.default.removeItem(at: output)
                            }
                        }
                    }
                }
            }
        }
    }

    func testLongPoleStartsWithEarlierFoldersPendingIncludingSaturatedSingleStreamWindow() async throws {
        for method in Self.methods {
            let root = try TestSupport.directory("7z-long-pole-submit-\(method)")
            let longStarted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let seen = Mutex<(Int, Int)?>(nil)
            let single = method == .lzma || method == .ppmd || method == .copy
            let count = method == .lzma ? 2 : single ? 4 : 2
            let task = Task.detached {
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                        if name == "long" { longStarted.signal() }
                        else { XCTAssertEqual(release.wait(timeout: .now() + 10), .success) }
                    }) {
                        try SevenZipWriter.$testingWillSubmit.withValue({ name, pending, oversized, threads in
                            if name == "long" { XCTAssertTrue(oversized); seen.withLock { $0 = (pending, threads) } }
                        }) {
                            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive"), format: .sevenZip,
                                options: Self.options(method, solid: true, filter: .delta(distance: 4)), lzmaChunkSize: Self.limit)
                            for index in 0..<count {
                                try writer.add(data: Self.payload(Self.limit), as: "medium-\(index)", modificationDate: TestSupport.date)
                            }
                            try writer.add(data: Self.payload(3 * Self.limit), as: "long", modificationDate: TestSupport.date)
                            try writer.finish()
                        }
                    }
                }
            }
            defer { for _ in 0..<count * 16 { release.signal() } }
            try await LZMA2ChunkPipelineTests.wait(longStarted)
            let observed = try XCTUnwrap(seen.withLock { $0 })
            XCTAssertEqual(observed.0, count)
            if single { XCTAssertEqual(observed.1, method == .lzma ? 2 : 1) }
            else if method != .bzip2 { XCTAssertEqual(observed.1, 2) }
            for _ in 0..<count * 16 { release.signal() }
            try await task.value
            try FileManager.default.removeItem(at: root)
        }
    }

    func testTwoCoreLZMALongPoleDrainsNormalReservationsAndUsesBothCores() throws {
        let root = try TestSupport.directory("7z-lzma-two-core-long-pole")
        defer { try? FileManager.default.removeItem(at: root) }
        for solid in [false, true] {
            let observed = Mutex<(Int, Int)?>(nil)
            let before = LZMAMatchFinderPipeline.testingWorkerCounts
            try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                try SevenZipWriter.$testingWillSubmit.withValue({ name, pending, streamed, threads in
                    if name == "long" {
                        XCTAssertTrue(streamed)
                        observed.withLock { $0 = (pending, threads) }
                    }
                }) {
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(solid).7z"), format: .sevenZip,
                        options: Self.options(.lzma, solid: solid, filter: solid ? .delta(distance: 4) : .none, threads: 2))
                    for index in 0..<2 {
                        try writer.add(data: Self.payload(Self.limit), as: "medium-\(index)", modificationDate: TestSupport.date)
                    }
                    try writer.add(data: Self.payload(3 * Self.limit), as: "long", modificationDate: TestSupport.date)
                    try writer.finish()
                }
            }
            let reservation = try XCTUnwrap(observed.withLock { $0 })
            XCTAssertEqual(reservation.0, 0)
            XCTAssertEqual(reservation.1, 2)
            let after = LZMAMatchFinderPipeline.testingWorkerCounts
            XCTAssertGreaterThan(after.starts, before.starts)
            XCTAssertEqual(after.live, before.live)
        }
    }

    func testWorkerFileInputMatchesOldDrainAndClosesSpools() throws {
        for method: SevenZipCompressionMethod in [.lzma, .ppmd, .bzip2] {
            let root = try TestSupport.directory("7z-long-pole-file-\(method)")
            let source = root.appendingPathComponent("source")
            try Self.payload(3 * Self.limit).write(to: source)
            var expected: Data?
            for old in [true, false] {
                let descriptors = Mutex<[Int32]>([]), reads = Mutex(0)
                let output = root.appendingPathComponent("\(old).7z")
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try SevenZipWriter.$testingOldDrain.withValue(old) {
                        try ScratchFile.$testingCreated.withValue({ fd in descriptors.withLock { $0.append(fd) } }) {
                            try FileJob.$testingDuringWorkerRead.withValue({ _, _ in reads.withLock { $0 += 1 } }) {
                                let writer = try ArchiveWriter.create(url: output, format: .sevenZip,
                                    options: Self.options(method, solid: false, filter: .none))
                                for index in 0..<3 {
                                    try writer.add(data: Self.payload(Self.limit / 2), as: "medium-\(index)", modificationDate: TestSupport.date)
                                }
                                try writer.add(contentsOf: source, as: "long")
                                try writer.finish()
                            }
                        }
                    }
                }
                if !old { XCTAssertGreaterThan(reads.withLock { $0 }, 0); XCTAssertGreaterThan(descriptors.withLock { $0.count }, 0) }
                for fd in descriptors.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1) }
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
            }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gyoshuku-") })
            try FileManager.default.removeItem(at: root)
        }
    }

    func testNonSolidSingleStreamStartsWhenAllMediumSlotsArePending() async throws {
        for method: SevenZipCompressionMethod in [.lzma, .ppmd] {
            let root = try TestSupport.directory("7z-long-pole-full-item-window-\(method)")
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let pending = Mutex<Int?>(nil)
            let task = Task.detached {
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                        if name == "long" { started.signal() }
                        else { XCTAssertEqual(release.wait(timeout: .now() + 10), .success) }
                    }) {
                        try SevenZipWriter.$testingWillSubmit.withValue({ name, count, streamed, threads in
                            if name == "long" {
                                XCTAssertTrue(streamed); XCTAssertEqual(threads, method == .lzma ? 2 : 1)
                                pending.withLock { $0 = count }
                            }
                        }) {
                            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive"), format: .sevenZip,
                                options: Self.options(method, solid: false, filter: .none))
                            for index in 0..<(method == .lzma ? 2 : 4) {
                                try writer.add(data: Self.payload(Self.limit), as: "medium-\(index)", modificationDate: TestSupport.date)
                            }
                            try writer.add(data: Self.payload(3 * Self.limit), as: "long", modificationDate: TestSupport.date)
                            try writer.finish()
                        }
                    }
                }
            }
            defer { for _ in 0..<32 { release.signal() } }
            try await LZMA2ChunkPipelineTests.wait(started)
            XCTAssertEqual(pending.withLock { $0 }, method == .lzma ? 2 : 4)
            for _ in 0..<32 { release.signal() }
            try await task.value
            try FileManager.default.removeItem(at: root)
        }
    }

    func testLargeBzip2UsesRealPieceReservationAndMatchesOldDrain() throws {
        let root = try TestSupport.directory("7z-long-pole-large-bzip2")
        defer { try? FileManager.default.removeItem(at: root) }
        let medium = Self.payload(Self.limit / 2), large = Self.payload((16 << 20) + 1)
        for solid in [false, true] {
            var expected: Data?
            for (old, threads) in [(true, 4), (false, 1), (false, 4), (false, 10), (false, 36)] {
                let output = root.appendingPathComponent(UUID().uuidString)
                let reservation = Mutex<(Int, Int)?>(nil)
                try SevenZipWriter.$testingOldDrain.withValue(old) {
                    try SevenZipWriter.$testingWillSubmit.withValue({ name, pending, streamed, inner in
                        if name == "long" { XCTAssertTrue(streamed); reservation.withLock { $0 = (pending, inner) } }
                    }) {
                        var options = Self.options(.bzip2, solid: solid, filter: .none, threads: threads)
                        options.sevenZipSolid = solid ? .on(blockSize: 1 << 20, filesPerBlock: 1) : .off
                        let writer = try ArchiveWriter.create(url: output, format: .sevenZip, options: options)
                        for index in 0..<3 {
                            try writer.add(data: medium, as: "medium-\(index)", modificationDate: TestSupport.date)
                        }
                        try writer.add(data: large, as: "long", modificationDate: TestSupport.date)
                        try writer.finish()
                    }
                }
                if !old && threads > 1 {
                    let observed = try XCTUnwrap(reservation.withLock { $0 })
                    XCTAssertGreaterThan(observed.0, 0)
                    XCTAssertEqual(observed.1, min(threads - observed.0,
                        ParallelBzip2StreamEncoder.estimatedChunkCount(size: UInt64(large.count), level: 1)))
                    XCTAssertLessThanOrEqual(observed.1, ParallelBzip2StreamEncoder.estimatedChunkCount(size: UInt64(large.count), level: 1))
                }
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertEqual(bytes, expected, "solid=\(solid), t=\(threads)") } else { expected = bytes }
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testRealSixteenMiBItemWindowStreamsLZMAAndPPMdFromFile() throws {
        let root = try TestSupport.directory("7z-long-pole-real-item-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Self.payload((16 << 20) + 1).write(to: source)
        for method: SevenZipCompressionMethod in [.lzma, .ppmd] {
            var expected: Data?
            for (old, threads) in [(true, 4), (false, 1), (false, 4), (false, 10), (false, 36)] {
                let output = root.appendingPathComponent(UUID().uuidString)
                let reads = Mutex(0)
                try SevenZipWriter.$testingOldDrain.withValue(old) {
                    try FileJob.$testingDuringWorkerRead.withValue({ _, _ in reads.withLock { $0 += 1 } }) {
                        let writer = try ArchiveWriter.create(url: output, format: .sevenZip,
                            options: Self.options(method, solid: false, filter: .none, threads: threads))
                        for index in 0..<3 {
                            try writer.add(data: Self.payload(1 << 20), as: "medium-\(index)", modificationDate: TestSupport.date)
                        }
                        try writer.add(contentsOf: source, as: "long")
                        XCTAssertLessThanOrEqual(writer.pendingInputBytes,
                            Self.options(method, solid: false, filter: .none, threads: threads).maximumPendingInputBytes(for: .sevenZip))
                        try writer.finish()
                    }
                }
                if !old && threads > 1 { XCTAssertGreaterThan(reads.withLock { $0 }, 0) }
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertEqual(bytes, expected, "\(method), t=\(threads)") } else { expected = bytes }
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testFailuresKeepLongPoleIndexAndPreferEarlierMediumIndex() throws {
        for solid in [false, true] {
            for earlier in [false, true] {
                let root = try TestSupport.directory("7z-long-pole-failure-\(solid)-\(earlier)")
                let output = root.appendingPathComponent("archive")
                var additions: [ArchiveAddition] = []
                for index in 0...3 {
                    let source = root.appendingPathComponent("source-\(index)")
                    try Self.payload(index == 3 ? 3 * Self.limit : Self.limit / 2).write(to: source)
                    additions.append(.init(path: index == 3 ? "long" : "medium-\(index)", source: .contents(of: source)))
                }
                let descriptors = Mutex<[Int32]>([])
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try ScratchFile.$testingCreated.withValue({ fd in descriptors.withLock { $0.append(fd) } }) {
                        try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                            if earlier && name == "medium-0" { Thread.sleep(forTimeInterval: 0.02); throw WriterError.compression(-70) }
                            if name == "long" { throw WriterError.compression(-71) }
                        }) {
                            let writer = try ArchiveWriter.create(url: output, format: .sevenZip,
                                options: Self.options(.ppmd, solid: solid, filter: .none))
                            XCTAssertThrowsError(try { try writer.add(additions, events: nil); try writer.finish() }()) { error in
                                let failure = error as? ArchiveAdditionError
                                XCTAssertEqual(failure?.index, earlier ? 0 : 3)
                                XCTAssertEqual(failure?.path, earlier ? "medium-0" : "long")
                                XCTAssertEqual(failure?.underlying as? WriterError, .compression(earlier ? -70 : -71))
                            }
                        }
                    }
                }
                for fd in descriptors.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gyoshuku-") })
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    func testCancellationDuringLongPoleReturnsPromptlyAndClosesSpools() async throws {
        for (solid, file) in [(false, false), (true, false), (false, true)] {
            let root = try TestSupport.directory("7z-long-pole-cancel-\(solid)-\(file)")
            let output = root.appendingPathComponent("archive")
            let source = root.appendingPathComponent("source")
            if file { try Self.payload(16 * Self.limit).write(to: source) }
            let started = DispatchSemaphore(value: 0), descriptors = Mutex<[Int32]>([])
            let task = Task.detached {
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try ScratchFile.$testingCreated.withValue({ fd in descriptors.withLock { $0.append(fd) } }) {
                        try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                            if name == "long" { started.signal(); Thread.sleep(forTimeInterval: 0.01) }
                        }) {
                            let writer = try ArchiveWriter.create(url: output, format: .sevenZip,
                                options: Self.options(.ppmd, solid: solid, filter: .none))
                            for index in 0..<3 {
                                try writer.add(data: Self.payload(Self.limit / 2), as: "medium-\(index)", modificationDate: TestSupport.date)
                            }
                            if file { try writer.add(contentsOf: source, as: "long") }
                            else { try writer.add(data: Self.payload(16 * Self.limit), as: "long", modificationDate: TestSupport.date) }
                            try writer.finish()
                        }
                    }
                }
            }
            try await LZMA2ChunkPipelineTests.wait(started)
            let cancelTime = Date()
            task.cancel()
            do { try await task.value; XCTFail("取消しが成功として返った") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(Date().timeIntervalSince(cancelTime), 2)
            for fd in descriptors.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), file ? ["source"] : [])
            try FileManager.default.removeItem(at: root)
        }
    }

    func testDiskSpoolHasInputBasedLimitWithoutFreeSpaceProbe() throws {
        let root = try TestSupport.directory("7z-long-pole-spool-bound")
        let limit = OrderedEntrySpool.sevenZipMaximumLength(size: 1)
        let spool = try OrderedEntrySpool(directory: root, tag: "7z-test", diskBacked: true, maximumLength: limit)
        try spool.append(Data(count: Int(limit)))
        XCTAssertThrowsError(try spool.append(Data([1]))) { XCTAssertEqual($0 as? WriterError, .sizeOverflow) }
        XCTAssertEqual(spool.length, limit)
        spool.close()
        XCTAssertEqual(OrderedEntrySpool.sevenZipMaximumLength(size: .max), .max)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testDidEmitReportsReservationsInFolderOrderAndLoneFinalFolderSkipsOutputSpool() throws {
        for method in Self.methods {
            let root = try TestSupport.directory("7z-long-pole-progress-\(method)")
            var position: UInt64 = 0
            let writer = SevenZipBlockWriter(options: Self.options(method, solid: true, filter: .delta(distance: 4)),
                directory: root, chunkSize: Self.limit)
            let sizes = [Self.limit / 2, Self.limit / 2 + 1, Self.limit / 2 + 2, 3 * Self.limit]
            for (index, size) in sizes.enumerated() {
                let data = Self.payload(size)
                var offset = 0
                try writer.add(name: "item-\(index)", mode: 0o100644, size: UInt64(size), date: TestSupport.date, read: { count in
                    let end = min(offset + count, data.count)
                    defer { offset = end }
                    return data.subdata(in: offset..<end)
                }, position: { position }, write: { position += UInt64($0.count) })
            }
            let pending = writer.pendingInputBytes
            // 長いfolderの片並列を確保するため、追加中に先頭が返却済みの場合がある。
            // flushは残る予約だけを投入順に返す。
            var expected = sizes.map { UInt64(min($0, Self.limit)) }
            while expected.reduce(0, +) > pending { expected.removeFirst() }
            var emissions: [UInt64] = []
            try writer.flush(position: { position }, write: { position += UInt64($0.count) }, didEmit: { emissions.append($0) })
            XCTAssertEqual(emissions, expected)
            // LZMAは通常二枠+long-pole二core。第三folderの追加時に先頭の予約を既に返す。
            if method == .lzma {
                XCTAssertEqual(emissions, sizes.dropFirst().map { UInt64(min($0, Self.limit)) })
            }
            XCTAssertEqual(emissions.reduce(0, +), pending)
            writer.abandon()
            let descriptors = Mutex<[Int32]>([])
            try ScratchFile.$testingCreated.withValue({ fd in descriptors.withLock { $0.append(fd) } }) {
                // BZip2は確定folderをflushまで保持するので、finalの直書き経路を観測できる。
                let lone = SevenZipBlockWriter(options: Self.options(.bzip2, solid: true, filter: .none), directory: root, chunkSize: nil)
                var remaining = 3 * Self.limit
                try lone.add(name: "lone", mode: 0o100644, size: UInt64(remaining), date: TestSupport.date, read: { count in
                    let size = min(count, remaining)
                    remaining -= size
                    return Data(count: size)
                }, position: { position }, write: { position += UInt64($0.count) })
                try lone.flush(position: { position }, write: { position += UInt64($0.count) })
                XCTAssertEqual(descriptors.withLock { $0.count }, 1)
                lone.abandon()
            }
            for fd in descriptors.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }
}
