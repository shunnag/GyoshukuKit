import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import GyoshukuKit

final class OrderedEntrySpoolTests: XCTestCase {
    func testStoredBatchKeepsLegacyPrefetchLimitAndIdenticalBytes() throws {
        let root = try TestSupport.directory("entry-spool-stored-batch")
        for method: CompressionMethod in [.bzip2, .lzma, .xz, .zstd, .ppmd] {
            let url = root.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writer = try ZipWriter(output: FileHandle(forWritingTo: url), url: url,
                options: .init(compressionMethod: method, compressionThreads: 4),
                deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode,
                salt: { Data(repeating: 0x37, count: 16) })
            XCTAssertEqual(writer.singleBlockLimit(name: "stored.png", mode: 0o100644, size: 2_097_152), 1_048_576)
            // BZip2の項目窓は既定level 9の5 block分まで。それ以上は内側のspliceへ渡す。
            let compressedLimit = method == .bzip2 ? min(16_777_216, 5 * (100_000 * 9 - 19)) : 16_777_216
            XCTAssertEqual(writer.singleBlockLimit(name: "compressed.txt", mode: 0o100644, size: 2_097_152), compressedLimit)
            writer.abort()
        }
        let source = root.appendingPathComponent("source")
        let payload = Data(repeating: 65, count: 1_048_577)
        try payload.write(to: source)
        for encrypted in [false, true] {
            var expected: Data?
            for threads in [1, 4] {
                for batch in [false, true] {
                    try AdditionProgressTestSupport.timestamp(source)
                    let url = root.appendingPathComponent(UUID().uuidString + ".zip")
                    let created = Mutex(0)
                    try ScratchFile.$testingCreated.withValue({ _ in created.withLock { $0 += 1 } }) {
                        let writer = try ArchiveWriter.create(url: url, format: .zip,
                            options: .init(compressionMethod: .zstd, password: encrypted ? "secret" : nil,
                                           compressionThreads: threads), zipSalt: { Data(repeating: 0x37, count: 16) },
                            lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                        if batch { try writer.add([ArchiveAddition(path: "stored.png", source: .contents(of: source))], events: nil) }
                        else { try writer.add(contentsOf: source, as: "stored.png") }
                        try writer.finish()
                    }
                    XCTAssertEqual(created.withLock { $0 }, 0)
                    let bytes = try Data(contentsOf: url)
                    if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                    let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: encrypted ? "secret" : nil))
                    XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), payload)
                }
            }
        }
    }

    func testMemoryThenSpillPreservesBytesAndClosesDescriptor() throws {
        let root = try TestSupport.directory("entry-spool")
        let descriptors = Mutex<[Int32]>([])
        try ScratchFile.$testingCreated.withValue({ fd in descriptors.withLock { $0.append(fd) } }) {
            let spool = try OrderedEntrySpool(directory: root, tag: "test-entry")
            try spool.append(Data())
            try spool.append(Data(repeating: 65, count: 1 << 20))
            XCTAssertNil(spool.scratch)
            XCTAssertEqual(descriptors.withLock { $0.count }, 0)
            try spool.append(Data([66]))
            XCTAssertEqual(descriptors.withLock { $0.count }, 1)
            XCTAssertEqual(spool.length, 1_048_577)
            var result = Data()
            try spool.forEachChunk { result.append($0) }
            XCTAssertEqual(result, Data(repeating: 65, count: 1 << 20) + Data([66]))
            let scratch = try XCTUnwrap(spool.scratch)
            spool.close()
            XCTAssertThrowsError(try scratch.handle.offset())
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testEmptyDirectoryAndStoredZIPCreateNoSpools() throws {
        let root = try TestSupport.directory("entry-spool-skipped")
        let created = Mutex(0)
        try ScratchFile.$testingCreated.withValue({ _ in created.withLock { $0 += 1 } }) {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("archive.zip"),
                options: .init(compressionMethod: .zstd, compressionThreads: 4))
            try writer.add(data: Data(), as: "empty")
            try writer.addDirectory("folder")
            try writer.add(data: Data(repeating: 65, count: 4096), as: "stored.png")
            try writer.finish()
        }
        XCTAssertEqual(created.withLock { $0 }, 0)
    }

    func testWorkerSpillPreservesScratchFaultInjection() throws {
        let root = try TestSupport.directory("entry-spool-worker-failure")
        try ScratchFile.$testingFreeSpaceReserve.withValue(UInt64.max) {
            let spool = try OrderedEntrySpool(directory: root, tag: "test-entry")
            let pipeline = OrderedChunkPipeline<OrderedEntrySpool, Int, Int>(threads: 2) { output in
                try output.append(Data(repeating: 65, count: 1_048_577))
                return 0
            }
            defer { pipeline.abandonAndWait() }
            try pipeline.submit(spool, tag: 0) { _, _ in XCTFail("unexpected output") }
            XCTAssertThrowsError(try pipeline.drain { _, _ in XCTFail("unexpected output") })
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSpillFailureKeepsMemoryAndReleasesScratch() throws {
        let root = try TestSupport.directory("entry-spool-failure")
        try ScratchFile.$testingFreeSpaceReserve.withValue(UInt64.max) {
            let spool = try OrderedEntrySpool(directory: root, tag: "test-entry")
            try spool.append(Data([65]))
            XCTAssertThrowsError(try spool.append(Data(repeating: 66, count: 1 << 20)))
            var result = Data()
            try spool.forEachChunk { result.append($0) }
            XCTAssertEqual(result, Data([65]))
            spool.close()
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
