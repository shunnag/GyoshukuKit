import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

final class BatchOutputTests: XCTestCase {
    private typealias B = BatchAdditionTestSupport
    private typealias S = AdditionProgressTestSupport

    func testUnobservedBatchBytesAcrossBufferFlushesAndHeaderPatches() throws {
        let root = try ZipTestSupport.directory("p7-buffer-bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.fixture(root)
        try ArchiveUpdater.$testingRandomBytes.withValue({ Data(repeating: 17, count: $0) }) {
            for encryption in 0..<3 {
                let options = WriterOptions(password: encryption == 0 ? nil : "password",
                                            zipEncryption: encryption == 2 ? .zipCrypto : .aes256, compressionThreads: 8)
                var expected: Data?
                for batch in [false, true] {
                    try B.resetDates(items)
                    let output = root.appendingPathComponent("\(encryption)-\(batch).zip")
                    let writer = try ArchiveWriter.create(url: output, format: .zip, options: options,
                        deflateBlockSize: 65536, zipSalt: { Data(repeating: 19, count: 16) },
                        lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                    try writer.add(data: Data([1, 2, 3]), as: "before", modificationDate: ZipTestSupport.date)
                    if batch { try writer.add(items, events: nil) } else { try B.singles(writer, items) }
                    // Stored data uses a seek to patch its header after the buffered records.
                    try writer.add(data: Data(repeating: 91, count: 300_000), as: "after.png", modificationDate: ZipTestSupport.date)
                    try writer.finishAdditions(progress: nil)
                    let prefix = try Data(contentsOf: output)
                    XCTAssertFalse(prefix.isEmpty)
                    try writer.finish()
                    let bytes = try Data(contentsOf: output)
                    XCTAssertTrue(bytes.starts(with: prefix))
                    if let expected { XCTAssertEqual(bytes, expected, "encryption=\(encryption)") }
                    else { expected = bytes }
                }
            }
        }
    }

    func testBatchFlushesBeforeReturningAndBeforeCallbacksAndKeepsPartialZIP() throws {
        let root = try ZipTestSupport.directory("p7-buffer-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.small(root)
        for observed in [false, true] {
            let output = root.appendingPathComponent("\(observed).zip")
            let writer = try ArchiveWriter.create(url: output, options: .init(compressionMethod: .stored))
            if observed {
                var previousSize = 0
                XCTAssertThrowsError(try writer.add(items, events: { event in
                    if case let .didFinish(index) = event {
                        let bytes = try Data(contentsOf: output)
                        XCTAssertGreaterThan(bytes.count, previousSize + 4096)
                        previousSize = bytes.count
                        if index == 2 { throw S.Failure.callback }
                    }
                })) { XCTAssertEqual($0 as? S.Failure, .callback) }
                XCTAssertThrowsError(try writer.finish())
            } else {
                try writer.add(items, events: nil)
                XCTAssertGreaterThan(try Data(contentsOf: output).count, items.count * 4096)
                try writer.finish()
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testBufferedWriteFailureBelongsToFirstUnwrittenItem() throws {
        let root = try ZipTestSupport.directory("p7-buffer-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.small(root)
        for unreadable in [false, true] {
            if unreadable { XCTAssertEqual(chmod(items[2].sourceURL!.path, 0), 0) }
            defer { chmod(items[2].sourceURL!.path, 0o644) }
            let output = root.appendingPathComponent("partial-\(unreadable).zip")
            try Data().write(to: output)
            let handle = try FileHandle(forReadingFrom: output)
            let writer = ArchiveWriter(output: handle, url: output,
                                       format: .zip, options: .init(compressionThreads: 8))
            XCTAssertThrowsError(try writer.add(items, events: nil)) {
                let failure = $0 as? ArchiveAdditionError
                XCTAssertEqual(failure?.index, 0)
                XCTAssertEqual(failure?.path, items[0].path)
                XCTAssertEqual(failure?.sourceURL, items[0].sourceURL)
            }
            XCTAssertThrowsError(try writer.finish())
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testSevenZipVerifiedDataKeepsConfiguredChunkBoundaries() throws {
        let root = try ZipTestSupport.directory("p7-sevenzip-verified")
        defer { try? FileManager.default.removeItem(at: root) }
        var items = try B.small(root, count: 3, size: 17)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "disk-1")
        items.insert(.init(path: "link", source: .contents(of: link)), at: 1)
        items.insert(.init(path: "directory", source: .directory(modificationDate: ZipTestSupport.date)), at: 2)
        items.append(.init(path: "empty", source: .contents(of: try S.file(root, "empty", size: 0))))
        try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 23, count: 16) }) {
            for chunkSize in [16, 32] {
                for encrypted in [false, true] {
                    var expected: Data?
                    for batch in [false, true] {
                        try B.resetDates(items)
                        let output = root.appendingPathComponent("\(chunkSize)-\(encrypted)-\(batch).7z")
                        let options = WriterOptions(password: encrypted ? "password" : nil,
                                                    encryptsSevenZipHeaders: encrypted, compressionThreads: 4)
                        let writer = try ArchiveWriter.create(url: output, format: .sevenZip, options: options, lzmaChunkSize: chunkSize)
                        try writer.add(data: Data([1, 2]), as: "before", modificationDate: ZipTestSupport.date)
                        if batch { try writer.add(items, events: nil) } else { try B.singles(writer, items) }
                        try writer.add(data: Data([3]), as: "after", modificationDate: ZipTestSupport.date)
                        try writer.finish()
                        let bytes = try Data(contentsOf: output)
                        if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                    }
                }
            }
        }
    }
}
