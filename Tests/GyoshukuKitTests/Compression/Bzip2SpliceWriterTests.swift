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
        let input = TestCorpus.random(700_013)
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
        XCTAssertGreaterThan(calls.withLock { $0 }, 1)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(try reader.read(reader.entries[0]), input)
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

    func testCancellationOfZIPAndSevenZipDoesNotWaitForBzip2Codec() async throws {
        for duringAdd in [false, true] {
            let input = TestCorpus.random(duringAdd ? 1_700_013 : 600_013)
            for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
                let root = try TestSupport.directory("bzip2-splice-cancel-\(format)-\(duringAdd)")
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
                let active = Mutex(0)
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
                        if duringAdd { XCTFail("add returned while codecs were blocked") }
                        try writer.finish()
                    }
                }
                defer { for _ in 0..<2 { release.signal() } }
                // 二つのcodecを同時に止め、取消し時にはまだ実行中であることを検査する。
                for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(started) }
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
        let input = TestCorpus.random(700_013)
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
