import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import GyoshukuKit

final class Bzip2SpliceWriterTests: XCTestCase {
    func testZIPMultiBlockRoundTripsWithAESAndZipCrypto() throws {
        let root = try TestSupport.directory("bzip2-splice-zip")
        let input = TestCorpus.random(700_013)
        for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
            var expected: Data?
            for threads in [1, 7] {
                let url = root.appendingPathComponent("\(String(describing: encryption))-\(threads).zip")
                let options = WriterOptions(compressionMethod: .bzip2, bzip2Level: 1,
                    password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256, compressionThreads: threads)
                let writer = try ArchiveWriter.create(url: url, format: .zip, options: options,
                    zipSalt: { Data(0..<16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                try writer.add(data: input, as: "large", modificationDate: TestSupport.date)
                try writer.finish()
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: options.password))
                XCTAssertEqual(try reader.read(reader.entries[0]), input)
                if encryption != .zipCrypto {
                    let bytes = try Data(contentsOf: url)
                    if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                }
            }
        }
    }

    func testZIPBatchDiskAdditionUsesInnerBzip2Parallelism() throws {
        let root = try TestSupport.directory("bzip2-splice-zip-batch")
        let source = root.appendingPathComponent("source")
        // 項目窓の5 block上限を超える入力は、サイズから求めた6片を内側codecへ渡す。
        let input = TestCorpus.random(5 * 99_981 + 137)
        try input.write(to: source)
        let calls = Mutex(0)
        let url = root.appendingPathComponent("archive.zip")
        try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
            calls.withLock { $0 += 1 }
            return try Bzip2StreamEncoder.encode(bytes, level: level)
        }) {
            let writer = try ArchiveWriter.create(url: url, format: .zip,
                options: WriterOptions(compressionMethod: .bzip2, bzip2Level: 1, compressionThreads: 7))
            try writer.add([ArchiveAddition(path: "large", source: .contents(of: source))], events: nil)
            try writer.finish()
        }
        XCTAssertEqual(calls.withLock { $0 }, 6)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(try reader.read(reader.entries[0]), input)
    }

    func testEntryWindowThresholdKeepsBytesAcrossThreadsAndBatchAddition() throws {
        let root = try TestSupport.directory("bzip2-entry-window-threshold")
        defer { try? FileManager.default.removeItem(at: root) }
        for (level, limit) in [(1, 499_905), (9, 4_499_905)] {
            XCTAssertEqual(ParallelBzip2StreamEncoder.entryWindowLimit(level: level), limit)
            XCTAssertLessThan(limit, ParallelBzip2StreamEncoder.inputCap)
            let sample = TestCorpus.random(limit + 1)
            for size in [limit - 1, limit, limit + 1] {
                let input = Data(sample.prefix(size))
                let items = try ["first", "second"].map { name -> ArchiveAddition in
                    let source = root.appendingPathComponent("source-\(name)")
                    try input.write(to: source)
                    return .init(path: name, source: .contents(of: source))
                }
                for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
                    var expected: Data?
                    for threads in [1, 7, 36] {
                        for batch in [false, true] {
                            try BatchAdditionTestSupport.resetDates(items)
                            let url = root.appendingPathComponent("\(level)-\(size)-\(format)-\(threads)-\(batch)")
                            let calls = Mutex(0)
                            try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                                calls.withLock { $0 += 1 }
                                return try Bzip2StreamEncoder.encode(bytes, level: level)
                            }) {
                                let writer = try ArchiveWriter.create(url: url, format: format,
                                    options: WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .bzip2,
                                        bzip2Level: level, useCompressionHeuristic: false, compressionThreads: threads))
                                if batch {
                                    try writer.add(items, events: { event in
                                        // ZIPの後続項目を準備する前にも、5 block以下の先行入力は窓に残る。
                                        if format == .zip, threads > 1, case .willStart(1) = event {
                                            XCTAssertEqual(writer.pendingInputBytes, size <= limit ? UInt64(size) : 0)
                                        }
                                    })
                                } else {
                                    for (index, item) in items.enumerated() {
                                        try writer.add(contentsOf: item.sourceURL!, as: item.path)
                                        if index == 0, threads > 1 {
                                            XCTAssertEqual(writer.pendingInputBytes, size <= limit ? UInt64(size) : 0)
                                        }
                                    }
                                }
                                try writer.finish()
                            }
                            // 項目窓は逐次libbz2、大項目だけ内側spliceの複数codecを使う。
                            let chunks = calls.withLock { $0 }
                            if threads > 1, size > limit { XCTAssertGreaterThan(chunks, 1) }
                            else { XCTAssertEqual(chunks, 0) }
                            let bytes = try Data(contentsOf: url)
                            if let expected {
                                XCTAssertEqual(bytes, expected, "level=\(level), size=\(size), format=\(format), threads=\(threads), batch=\(batch)")
                            } else {
                                expected = bytes
                                let reader = try ArchiveReader.open(url: url)
                                for entry in reader.entries { XCTAssertEqual(try reader.read(entry), input) }
                            }
                            try FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
        }
    }

    func testSevenZipMultiBlockSolidAndNonSolidWithFiltersAndAES() throws {
        let root = try TestSupport.directory("bzip2-splice-7z")
        let input = TestCorpus.random(700_013)
        for solid in [false, true] {
            for filtered in [false, true] {
                for encrypted in [false, true] {
                    var expected: Data?
                    for threads in [1, 7] {
                        let url = root.appendingPathComponent("\(solid)-\(filtered)-\(encrypted)-\(threads).7z")
                        let options = WriterOptions(sevenZipMethod: .bzip2,
                            sevenZipSolid: solid ? .on(blockSize: 2 << 20, filesPerBlock: nil) : .off,
                            sevenZipFilter: filtered ? .delta(distance: 3) : .none, bzip2Level: 1,
                            password: encrypted ? "secret" : nil, compressionThreads: threads)
                        try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 0x17, count: 16) }) {
                            let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: options)
                            try writer.add(data: input, as: "large", modificationDate: TestSupport.date)
                            if solid { try writer.add(data: Data("solid tail".utf8), as: "tail", modificationDate: TestSupport.date) }
                            try writer.finish()
                        }
                        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: options.password))
                        XCTAssertEqual(try reader.read(reader.entries[0]), input)
                        if solid { XCTAssertEqual(try reader.read(reader.entries[1]), Data("solid tail".utf8)) }
                        let bytes = try Data(contentsOf: url)
                        if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                    }
                }
            }
        }
    }

    func testFilteredSolidFoldersShareThreadReservations() throws {
        let root = try TestSupport.directory("bzip2-splice-filtered-reservations")
        let options = WriterOptions(sevenZipMethod: .bzip2,
            sevenZipSolid: .on(blockSize: 1 << 20, filesPerBlock: 1), sevenZipFilter: .delta(distance: 4),
            bzip2Level: 1, compressionThreads: 8)
        let writer = SevenZipBlockWriter(options: options, directory: root, chunkSize: nil)
        var output = Data()
        // 固定1 block幅の3片を使い、folderごとの予約は従来どおり2 codecに分配する。
        let input = TestCorpus.random(2 * 99_981 + 137)
        for index in 0..<3 {
            var offset = 0
            try writer.add(name: "folder-\(index)", mode: 0o100644, size: UInt64(input.count), date: TestSupport.date, read: { count in
                let end = min(offset + count, input.count)
                defer { offset = end }
                return input.subdata(in: offset..<end)
            }, position: { UInt64(output.count) }, write: { output.append($0) })
            // 単独folderを早く予約せず、次folderが確定した後も前の予約をdrainしない。
            XCTAssertEqual(writer.assignedThreads, 2 * index)
        }
        try writer.flush(position: { UInt64(output.count) }, write: { output.append($0) })
        XCTAssertEqual(writer.assignedThreads, 0)
        XCTAssertEqual(writer.pendingInputBytes, 0)
        XCTAssertFalse(output.isEmpty)
    }

    func testSingleFilteredSolidFolderUsesAllFourCodecs() async throws {
        let root = try TestSupport.directory("bzip2-splice-single-filtered-solid")
        let url = root.appendingPathComponent("archive.7z")
        // サイズだけで決まる1 block幅の5片が、4 codecを同時に開始できる。
        let input = TestCorpus.random(4 * 99_981 + 137)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let activity = Mutex((running: 0, peak: 0))
        let task = Task.detached {
            try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                activity.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                defer { activity.withLock { $0.running -= 1 } }
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                return try Bzip2StreamEncoder.encode(bytes, level: level)
            }) {
                let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                    options: WriterOptions(sevenZipMethod: .bzip2, sevenZipSolid: .on(blockSize: UInt64(input.count)),
                        sevenZipFilter: .delta(distance: 4), bzip2Level: 1, compressionThreads: 4))
                try writer.add(data: input, as: "large", modificationDate: TestSupport.date)
                try writer.finish()
            }
        }
        defer { for _ in 0..<8 { release.signal() } }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(started) }
        XCTAssertEqual(activity.withLock { $0.peak }, 4)
        for _ in 0..<8 { release.signal() }
        try await task.value
        XCTAssertEqual(activity.withLock { $0.running }, 0)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(try reader.read(reader.entries[0]), input)
    }

    func testCancellationOfZIPAndSevenZipDoesNotWaitForBzip2Codec() async throws {
        for duringAdd in [false, true] {
            // 両方とも項目窓の上限を超える。長いrunなら2片、乱数ならadd中の容量待ち。
            let input = duringAdd ? TestCorpus.random(6 * 99_981 + 137)
                : TestCorpus.random(99_981 + 137) + Data(repeating: 65, count: 5 * 99_981)
            for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
                let root = try TestSupport.directory("bzip2-splice-cancel-\(format)-\(duringAdd)")
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
                let active = Mutex(0)
                let added = Mutex(false)
                let task = Task.detached {
                    try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                        active.withLock { $0 += 1 }
                        started.signal()
                        XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                        defer { completed.signal() }
                        return try Bzip2StreamEncoder.encode(bytes, level: level)
                    }) {
                        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive"), format: format,
                            options: WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .bzip2, bzip2Level: 1, compressionThreads: 2))
                        try writer.add(data: input, as: "large")
                        added.withLock { $0 = true }
                        if duringAdd { XCTFail("add returned while codecs were blocked") }
                        try writer.finish()
                    }
                }
                defer { for _ in 0..<2 { release.signal() } }
                // 二つのcodecを同時に止め、取消し時にはまだ実行中であることを検査する。
                for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(started) }
                // 両形式とも大項目はadd中にcodecを完結するので、codec待ちでaddはまだ戻らない。
                XCTAssertFalse(added.withLock { $0 })
                let begin = ContinuousClock.now
                task.cancel()
                do { try await task.value; XCTFail("cancelled writer succeeded") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                XCTAssertLessThan(begin.duration(to: .now), .milliseconds(250))
                XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
                for _ in 0..<2 { release.signal() }
                for _ in 0..<active.withLock({ $0 }) { try await LZMA2ChunkPipelineTests.wait(completed) }
            }
        }
    }

    func testSolidFolderCancellationReleasesSourceWithoutWaitingForCodecs() async throws {
        let root = try TestSupport.directory("bzip2-splice-solid-cancel")
        // 7片は4 codecの枠を超え、sourceを保持した容量待ちで取消しを観測する。
        let input = TestCorpus.random(6 * 99_981 + 137)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                defer { completed.signal() }
                return try Bzip2StreamEncoder.encode(bytes, level: level)
            }) {
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive.7z"), format: .sevenZip,
                    options: WriterOptions(sevenZipMethod: .bzip2, sevenZipSolid: .on(blockSize: UInt64(input.count)),
                        bzip2Level: 1, compressionThreads: 4))
                try writer.add(data: input, as: "large")
                try writer.finish()
            }
        }
        defer { for _ in 0..<4 { release.signal() } }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(started) }
        let begin = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("cancelled solid writer succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(begin.duration(to: .now), .milliseconds(250))
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive.7z").path))
        for _ in 0..<4 { release.signal() }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(completed) }
    }

    func testSingleSixteenMiBEntriesUseTwelveCodecsFullSize() async throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        let root = try TestSupport.directory("bzip2-splice-twelve-cores")
        let input = TestCorpus.random(16 << 20)
        let sequentialStart = ContinuousClock.now
        let sequential = try Bzip2StreamEncoder.encode(input, level: 9)
        let sequentialTime = sequentialStart.duration(to: .now)
        let parallel = try ParallelBzip2StreamEncoder(level: 9, threads: 12, size: UInt64(input.count))
        var output = Data()
        let parallelStart = ContinuousClock.now
        try parallel.write(input, finish: true) { output.append($0) }
        let parallelTime = parallelStart.duration(to: .now)
        XCTAssertEqual(parallel.forcedCuts, 0)
        XCTAssertEqual(output, sequential)
        TestSupport.report("BZIP2 16 MiB level 9 sequential=\(sequentialTime), threads12=\(parallelTime), byte-identical")
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let activity = Mutex((running: 0, peak: 0))
            let url = root.appendingPathComponent("\(format)")
            let task = Task.detached {
                try ParallelBzip2StreamEncoder.$testingEncoder.withValue({ bytes, level in
                    activity.withLock { state in state.running += 1; state.peak = max(state.peak, state.running) }
                    defer { activity.withLock { $0.running -= 1 } }
                    started.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 30), .success)
                    return try Bzip2StreamEncoder.encode(bytes, level: level)
                }) {
                    let writer = try ArchiveWriter.create(url: url, format: format,
                        options: WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .bzip2, bzip2Level: 9, compressionThreads: 12))
                    try writer.add(data: input, as: "large", modificationDate: TestSupport.date)
                    try writer.finish()
                }
            }
            defer { for _ in 0..<64 { release.signal() } }
            for _ in 0..<12 { try await LZMA2ChunkPipelineTests.wait(started) }
            XCTAssertEqual(activity.withLock { $0.peak }, 12)
            for _ in 0..<64 { release.signal() }
            try await task.value
            XCTAssertEqual(activity.withLock { $0.running }, 0)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(try reader.read(reader.entries[0]), input)
        }
    }

    func testAbandonDiscardsLateResultsAndInvalidatesEncoder() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let encoder = try ParallelBzip2StreamEncoder(level: 1, threads: 2, chunkSize: 99_981, encoder: { bytes, level in
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
            defer { completed.signal() }
            return try Bzip2StreamEncoder.encode(bytes, level: level)
        })
        defer { for _ in 0..<2 { release.signal() } }
        try encoder.write(TestCorpus.random(210_013), finish: false) { _ in XCTFail("early output") }
        for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(started) }
        let begin = ContinuousClock.now
        encoder.abandon()
        XCTAssertLessThan(begin.duration(to: .now), .milliseconds(250))
        XCTAssertEqual(encoder.pendingInputBytes, 0)
        XCTAssertThrowsError(try encoder.write(Data(), finish: true) { _ in XCTFail("late output") })
        for _ in 0..<2 { release.signal() }
        for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(completed) }
        XCTAssertEqual(encoder.pendingInputBytes, 0)
    }
}
