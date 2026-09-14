import Foundation
import GyoshukuKit
import KaitoKit
import XCTest

final class ArchiveUpdaterOptionsTests: XCTestCase {
    private let payload = Data(repeating: 0x41, count: 200 * 1024)

    private func original(_ label: String, empty: Bool = false) throws -> URL {
        let directory = try ZipTestSupport.directory("updater-options-\(label)")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        if !empty {
            try writer.add(data: Data("original entry\n".utf8), as: "old.txt", modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        return url
    }

    private func append(_ url: URL, as path: String = "payload.txt", options: WriterOptions) throws -> ArchiveEntry {
        let updater = try ArchiveUpdater.open(url: url, options: options)
        let names = updater.entryNames
        try updater.add(data: payload, as: path, modificationDate: ZipTestSupport.date)
        try updater.commit()
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), names + [path])
        let entry = try XCTUnwrap(reader.entries.last)
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try reader.read(entry), payload)
        return entry
    }

    func testAppendUsesStoredCompression() throws {
        for empty in [false, true] {
            let url = try original("stored-\(empty)", empty: empty)
            let entry = try append(url, options: WriterOptions(compressionMethod: .stored))

            XCTAssertEqual(entry.methodDescription, "stored")
            XCTAssertEqual(entry.compressedSize, entry.uncompressedSize)
        }
    }

    func testAppendHonorsDeflateLevels() throws {
        var sizes: [UInt64] = []
        for level in [1, 9] {
            let url = try original("deflate-\(level)")
            let options = WriterOptions(compressionMethod: .deflate, deflateLevel: level)
            let entry = try append(url, options: options)
            let size = try XCTUnwrap(entry.compressedSize)
            XCTAssertEqual(entry.methodDescription, "deflate")
            XCTAssertLessThan(size, UInt64(payload.count))
            sizes.append(size)

            // 新規作成と照合し、level が既定値に戻らないことも確認する。
            let reference = url.deletingLastPathComponent().appendingPathComponent("writer.zip")
            let writer = try ArchiveWriter.create(url: reference, options: options)
            try writer.add(data: payload, as: "payload.txt", modificationDate: ZipTestSupport.date)
            try writer.finish()
            let referenceEntry = try XCTUnwrap(ArchiveReader.open(url: reference).entries.first)
            XCTAssertEqual(entry.compressedSize, referenceEntry.compressedSize)
        }
        XCTAssertLessThanOrEqual(sizes[1], sizes[0])
    }

    func testOpenRejectsInvalidDeflateLevelWithoutChangingArchive() throws {
        let url = try original("invalid-level")
        let before = try Data(contentsOf: url)
        for level in [-1, 10] {
            XCTAssertThrowsError(try ArchiveUpdater.open(url: url, options: WriterOptions(deflateLevel: level))) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("deflateLevel"))
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testOpenRejectsUnsupportedMetadataWithoutChangingArchive() throws {
        let url = try original("unsupported-metadata")
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try ArchiveUpdater.open(url: url, options: WriterOptions(preserveMacOSMetadata: true))) {
            XCTAssertEqual($0 as? WriterError, .unsupportedOption("preserveMacOSMetadata"))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOpenValidatesOptionsBeforeAccessingArchive() throws {
        let directory = try ZipTestSupport.directory("updater-options-validation-order")
        let url = directory.appendingPathComponent("missing.zip")
        let invalidOptions: [(WriterOptions, WriterError)] = [
            (WriterOptions(deflateLevel: 10), .invalidOption("deflateLevel")),
            (WriterOptions(preserveMacOSMetadata: true), .unsupportedOption("preserveMacOSMetadata"))
        ]
        for (options, error) in invalidOptions {
            XCTAssertThrowsError(try ArchiveUpdater.open(url: url, options: options)) {
                XCTAssertEqual($0 as? WriterError, error)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAppendHonorsCompressionHeuristic() throws {
        for heuristic in [false, true] {
            let url = try original("heuristic-\(heuristic)")
            let options = WriterOptions(compressionMethod: .deflate, useCompressionHeuristic: heuristic)
            let entry = try append(url, as: "payload.png", options: options)

            XCTAssertEqual(entry.methodDescription, heuristic ? "stored" : "deflate")
            if heuristic {
                XCTAssertEqual(entry.compressedSize, entry.uncompressedSize)
            } else {
                XCTAssertLessThan(try XCTUnwrap(entry.compressedSize), UInt64(payload.count))
            }
        }
    }
}
