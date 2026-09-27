import Foundation
import XCTest
@testable import GyoshukuKit

final class ParallelCompressionLifecycleTests: XCTestCase {
    private static let blockSize = 64 * 1024

    func testSeparateZIPAddsEncodeConcurrently() async throws {
        let directory = try ZipTestSupport.directory("m8-concurrent-disk-adds")
        let source = directory.appendingPathComponent("source")
        try Data("one small file".utf8).write(to: source)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("archive.zip"), format: .zip,
                options: WriterOptions(compressionThreads: 4), deflateEncoder: { block, level in
                    started.signal()
                    XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                    return try DeflateBlock.encode(block, level: level)
                }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
            for index in 0..<4 { try writer.add(contentsOf: source, as: "file-\(index)") }
            try writer.finish()
        }
        defer { for _ in 0..<4 { release.signal() } }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(started) }
        for _ in 0..<4 { release.signal() }
        try await task.value
    }

    func testCancellationDuringAddAndFinishDoesNotWaitForCodec() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .tarBzip2] {
            for duringAdd in [false, true] {
                let directory = try ZipTestSupport.directory("m8-cancel-\(format)-\(duringAdd)")
                let url = directory.appendingPathComponent("archive")
                let alias = directory.appendingPathComponent("alias")
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let completed = DispatchSemaphore(value: 0)
                let task = Task.detached {
                    let writer = try ArchiveWriter.create(url: url, format: format,
                        options: WriterOptions(bzip2Level: 1, compressionThreads: 1), deflateBlockSize: ParallelCompressionLifecycleTests.blockSize,
                        deflateEncoder: { block, level in
                            started.signal()
                            XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                            defer { completed.signal() }
                            return try DeflateBlock.encode(block, level: level)
                        }, bzip2Encoder: { input, level in
                            started.signal()
                            XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                            defer { completed.signal() }
                            return try ParallelBzip2Compressor.encode(input, level: level)
                        }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                    try FileManager.default.linkItem(at: url, to: alias)
                    let chunkSize = format == .tarBzip2 ? ParallelBzip2Compressor.chunkSize(level: 1) : ParallelCompressionLifecycleTests.blockSize
                    try writer.add(data: Data(repeating: 0x41, count: duringAdd ? 3 * chunkSize : 1000), as: "file")
                    if duringAdd { XCTFail("add returned while the first worker was blocked") }
                    try writer.finish()
                }
                defer { release.signal() }
                try await LZMA2ChunkPipelineTests.wait(started)
                task.cancel()
                do { try await task.value; XCTFail("cancelled writer succeeded") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                // worker を止めたまま呼出側が戻ることを検証する。
                XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
                if format != .zip {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                    XCTAssertEqual(try Data(contentsOf: alias).count, 0)
                } else {
                    // ZIP の部分出力は従来どおり呼出側が削除する。
                    try FileManager.default.removeItem(at: url)
                }
                release.signal()
                try await LZMA2ChunkPipelineTests.wait(completed)
            }
        }
    }

    func testBoundedInputIncludesAssemblyWhileLaterResultsWait() async throws {
        let directory = try ZipTestSupport.directory("m8-bounded-input")
        let source = directory.appendingPathComponent("source")
        try Data(repeating: 0, count: 5 * ParallelCompressionLifecycleTests.blockSize).write(to: source)
        let firstStarted = DispatchSemaphore(value: 0), laterFinished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("archive.zip"), format: .zip,
                options: WriterOptions(compressionThreads: 3), deflateBlockSize: ParallelCompressionLifecycleTests.blockSize,
                deflateEncoder: { block, level in
                    if block.input.first == 0 {
                        firstStarted.signal()
                        XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
                    } else { laterFinished.signal() }
                    return try DeflateBlock.encode(block, level: level)
                }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
            var readCount = 0
            do {
                try writer.add(contentsOf: source, as: "file") { _, count in
                    let result = Data(repeating: UInt8(readCount / ParallelCompressionLifecycleTests.blockSize), count: count)
                    readCount += count
                    return result
                }
                XCTFail("unbounded input or missing cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            return readCount
        }
        defer { release.signal() }
        try await LZMA2ChunkPipelineTests.wait(firstStarted)
        for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(laterFinished) }
        task.cancel()
        let readCount = try await task.value
        XCTAssertEqual(readCount, 3 * ParallelCompressionLifecycleTests.blockSize)
    }

    func testDeferredEncoderErrorsInvalidateWriterAndRemoveTarOutput() throws {
        let directory = try ZipTestSupport.directory("m8-encoder-errors")
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .tarBzip2] {
            for threads in [1, 4] {
                let url = directory.appendingPathComponent("\(format)-\(threads)")
                let writer = try ArchiveWriter.create(url: url, format: format,
                    options: WriterOptions(compressionThreads: threads),
                    deflateEncoder: { _, _ in throw WriterError.compression(-77) },
                    bzip2Encoder: { _, _ in throw WriterError.compression(-77) },
                    lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                try writer.add(data: Data("queued".utf8), as: "first")
                if format == .zip && threads == 1 {
                    XCTAssertThrowsError(try writer.add(data: Data("next".utf8), as: "next")) {
                        XCTAssertEqual($0 as? WriterError, .compression(-77))
                    }
                } else {
                    XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .compression(-77)) }
                }
                XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
                if format != .zip { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            }
        }
    }

    func testZipCryptoKeepsSerialEncoder() throws {
        let directory = try ZipTestSupport.directory("m8-zipcrypto-serial")
        let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("archive.zip"), format: .zip,
            options: WriterOptions(password: "password", zipEncryption: .zipCrypto, compressionThreads: 8),
            deflateEncoder: { _, _ in XCTFail("ZipCrypto entered parallel encoder"); throw WriterError.invalidState },
            lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        try writer.add(data: Data(repeating: 0x41, count: 3 * ParallelCompressionLifecycleTests.blockSize), as: "file")
        try writer.finish()
    }
}
