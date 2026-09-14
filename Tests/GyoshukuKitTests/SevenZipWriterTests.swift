import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class SevenZipWriterTests: XCTestCase {
    func testSimpleArchiveExternalToolsAndKaitoRoundTrip() throws {
        let directory = try ZipTestSupport.directory("7z-simple")
        let url = directory.appendingPathComponent("archive.7z")
        let items: [SevenZipTestSupport.Expected] = [
            .init(name: "hello.txt", data: Data("hello 7z\n".utf8)),
            .init(name: "nested/binary", data: Data((0..<200_003).map { UInt8(truncatingIfNeeded: $0) }))
        ]
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        XCTAssertEqual(writer.format, .sevenZip)
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: item.date) }
        try writer.finish()
        try writer.finish()
        let bytes = try SevenZipBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.unpackedSizes, items.map { UInt64($0.data.count) })
        XCTAssertEqual(bytes.crcs, items.map { CRC32.checksum($0.data) })
        try SevenZipTestSupport.verify(url, expected: items)
        let listing = try String(contentsOf: directory.appendingPathComponent("7zz-l-slt.log"), encoding: .utf8)
        ZipTestSupport.report("APPLE LZMA2 properties: \(bytes.properties.map { String(format: "0x%02x", $0) })")
        XCTAssertEqual(bytes.properties, [0x16, 0x16])
        XCTAssertEqual(SevenZipTestSupport.listingEntries(listing).map { $0["Method"] }, ["LZMA2:23", "LZMA2:23"])
        XCTAssertTrue(listing.contains("Blocks = 2"), listing)
    }

    func testEmptyFilesDirectoriesAndMixedBitVectors() throws {
        let directory = try ZipTestSupport.directory("7z-empty-mixed")
        let url = directory.appendingPathComponent("archive.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        var expected: [SevenZipTestSupport.Expected] = []
        // 両方の bit vector が byte 境界を跨ぎ、全 entry と empty entry の添字が異なる入力。
        for index in 0..<18 {
            switch index % 3 {
            case 0:
                let item = SevenZipTestSupport.Expected(name: "file-\(index)", data: Data([UInt8(index)]))
                try writer.add(data: item.data, as: item.name, modificationDate: item.date)
                expected.append(item)
            case 1:
                try writer.add(data: Data(), as: "empty-\(index)", modificationDate: ZipTestSupport.date)
                expected.append(.init(name: "empty-\(index)"))
            default:
                try writer.addDirectory("dir-\(index)")
                expected.append(.init(name: "dir-\(index)/", kind: .directory, mode: 0o755, date: nil))
            }
        }
        try writer.finish()
        let bytes = try SevenZipBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.fileCount, 18)
        XCTAssertEqual(bytes.packedSizes.count, 6)
        XCTAssertEqual(bytes.fileProperties[0x0E], Data([0x6D, 0xB6, 0xC0]))
        XCTAssertEqual(bytes.fileProperties[0x0F], Data([0xAA, 0xA0]))
        try SevenZipTestSupport.verify(url, expected: expected)
        let listing = try SevenZipTestSupport.run(["l", url.path], in: directory, log: "7zz-l")
        XCTAssertTrue(listing.split(separator: "\n").contains { $0.contains("D....") && $0.contains("dir-2") }, listing)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries[1].formatSpecific["emptyStream"], "true")
        XCTAssertEqual(reader.entries[1].formatSpecific["emptyFile"], "true")
        XCTAssertEqual(reader.entries[2].formatSpecific["emptyFile"], "false")
    }

    func testEmptyArchiveAndOnlyEmptyStreams() throws {
        for variant in 0..<3 {
            let directory = try ZipTestSupport.directory("7z-empty-\(variant)")
            let url = directory.appendingPathComponent("archive.7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            var expected: [SevenZipTestSupport.Expected] = []
            if variant == 1 {
                try writer.addDirectory("directory")
                expected = [.init(name: "directory/", kind: .directory, mode: 0o755, date: nil)]
            } else if variant == 2 {
                try writer.add(data: Data(), as: "empty", modificationDate: ZipTestSupport.date)
                expected = [.init(name: "empty")]
            }
            try writer.finish()
            XCTAssertTrue(try SevenZipBytes(Data(contentsOf: url)).packedSizes.isEmpty)
            try SevenZipTestSupport.verify(url, expected: expected)
        }
    }

    func testJapaneseNamesAreUTF16LEAndByteExact() throws {
        let directory = try ZipTestSupport.directory("7z-japanese")
        let url = directory.appendingPathComponent("archive.7z")
        let names = ["日本語/資料.txt", "ガラス/凝縮🗂.txt"]
        let payload = Data("こんにちは\n".utf8)
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        for name in names {
            try writer.add(data: payload, as: name.decomposedStringWithCanonicalMapping, modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        let bytes = try SevenZipBytes(Data(contentsOf: url))
        let nameBytes = try XCTUnwrap(names.map { $0 + "\0" }.joined().data(using: .utf16LittleEndian))
        XCTAssertEqual(bytes.fileProperties[0x11], Data([0]) + nameBytes)
        try SevenZipTestSupport.verify(url, expected: names.map { .init(name: $0, data: payload) })
        let listing = try SevenZipTestSupport.run(["l", url.path], in: directory, log: "7zz-l")
        for name in names { XCTAssertNotNil(Data(listing.utf8).range(of: Data(name.utf8))) }
    }

    func testStartHeaderCRCCorruptionIsRefused() throws {
        let directory = try ZipTestSupport.directory("7z-start-crc")
        let url = try smallArchive(in: directory)
        var data = try Data(contentsOf: url)
        _ = try SevenZipBytes(data)
        data[8] ^= 1
        try data.write(to: url)
        let text = try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-corrupt", success: false)
        XCTAssertTrue(text.contains("Cannot open the file as [7z] archive"), text)
        XCTAssertThrowsError(try ArchiveReader.open(url: url))
    }

    func testNextHeaderCRCCorruptionIsRefusedIndependently() throws {
        let directory = try ZipTestSupport.directory("7z-next-crc")
        let url = try smallArchive(in: directory)
        var data = try Data(contentsOf: url)
        _ = try SevenZipBytes(data)
        data[28] ^= 1
        // NextHeaderCRC は StartHeaderCRC の対象でもある。外側を直して内側の検査だけを失敗させる。
        SevenZipTestSupport.patchCRC(&data, at: 8, over: 12..<32)
        try data.write(to: url)
        let text = try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-corrupt", success: false)
        XCTAssertTrue(text.contains("Headers Error"), text)
        XCTAssertThrowsError(try ArchiveReader.open(url: url))
    }

    func testPayloadCorruptionReportsSpecificFileCRC() throws {
        let directory = try ZipTestSupport.directory("7z-payload-crc")
        let url = directory.appendingPathComponent("archive.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(data: Data([0x51]), as: "damaged.txt", modificationDate: ZipTestSupport.date)
        try writer.add(data: Data("unaffected".utf8), as: "intact.txt", modificationDate: ZipTestSupport.date)
        try writer.finish()
        var data = try Data(contentsOf: url)
        let bytes = try SevenZipBytes(data)
        XCTAssertEqual(bytes.crcs[0], CRC32.checksum(Data([0x51])))
        // Apple が一 byte を raw chunk にしたことを確かめ、制御 byte ではなく literal を壊す。
        XCTAssertEqual(data.subdata(in: 32..<37), Data([1, 0, 0, 0x51, 0]))
        data[35] ^= 1
        try data.write(to: url)
        let text = try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-corrupt", success: false)
        XCTAssertTrue(text.contains("CRC Failed : damaged.txt"), text)
        XCTAssertFalse(text.contains("CRC Failed : intact.txt"), text)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertThrowsError(try reader.read(reader.entries[0]))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data("unaffected".utf8))
    }

    func testTimestampKnownValuesTruncationAndRange() throws {
        XCTAssertEqual(try SevenZipRecords.timestamp(Date(timeIntervalSince1970: 0)), 116_444_736_000_000_000)
        XCTAssertEqual(try SevenZipRecords.timestamp(ZipTestSupport.date), 133_444_736_010_000_000)
        XCTAssertEqual(try SevenZipRecords.timestamp(Date(timeIntervalSince1970: 1_700_000_001.875)), 133_444_736_010_000_000)
        XCTAssertEqual(try SevenZipRecords.timestamp(Date(timeIntervalSince1970: -1.25)), 116_444_735_980_000_000)
        XCTAssertEqual(try SevenZipRecords.timestamp(Date(timeIntervalSince1970: -11_644_473_600)), 0)
        for seconds in [Double.nan, .infinity, -.infinity, -11_644_473_601, Double(UInt64.max)] {
            XCTAssertThrowsError(try SevenZipRecords.timestamp(Date(timeIntervalSince1970: seconds))) {
                XCTAssertEqual($0 as? WriterError, .invalidDate)
            }
        }
    }

    func testMtimeAndExecutablePermissionsSurviveExtraction() throws {
        let directory = try ZipTestSupport.directory("7z-metadata")
        let url = directory.appendingPathComponent("archive.7z")
        let payload = Data("#!/bin/sh\necho fixture\n".utf8)
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(data: payload, as: "executable", modificationDate: ZipTestSupport.date, permissions: 0o755)
        try writer.finish()
        let bytes = try SevenZipBytes(Data(contentsOf: url))
        let attributes = try XCTUnwrap(bytes.fileProperties[0x15])
        XCTAssertEqual(Array(attributes.prefix(2)), [1, 0])
        XCTAssertEqual(SevenZipTestSupport.uint32(attributes, 2), 0x81ED_8020)
        let times = try XCTUnwrap(bytes.fileProperties[0x14])
        XCTAssertEqual(SevenZipTestSupport.uint64(times, 2), 133_444_736_010_000_000)
        try SevenZipTestSupport.verify(url, expected: [.init(name: "executable", data: payload, mode: 0o755)])
        let listing = try String(contentsOf: directory.appendingPathComponent("7zz-l-slt.log"), encoding: .utf8)
        XCTAssertEqual(SevenZipTestSupport.listingEntries(listing).first?["Modified"], "2023-11-14 22:13:21.0000000")
        let restored = directory.appendingPathComponent("extracted/executable")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: restored.path))
        let actual = try FileManager.default.attributesOfItem(atPath: restored.path)
        XCTAssertEqual((actual[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(actual[.modificationDate] as? Date, ZipTestSupport.date)
    }

    func testLargeRepetitiveFileCompressesAndRoundTrips() throws {
        let directory = try ZipTestSupport.directory("7z-large")
        let url = directory.appendingPathComponent("archive.7z")
        let payload = Data(String(repeating: "大きなファイルの LZMA2 round trip.\n", count: 80_000).utf8)
        XCTAssertGreaterThan(payload.count, 1024 * 1024)
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(data: payload, as: "large.txt", modificationDate: ZipTestSupport.date)
        try writer.finish()
        let data = try Data(contentsOf: url)
        XCTAssertLessThan(data.count, payload.count / 10)
        XCTAssertEqual(try SevenZipBytes(data).packedSizes.count, 1)
        try SevenZipTestSupport.verify(url, expected: [.init(name: "large.txt", data: payload)])
        ZipTestSupport.report("7Z LARGE: \(payload.count) input bytes -> \(data.count) archive bytes; KaitoKit and 7zz restored every byte")
    }

    func testDiskTreeAndLinksUseSharedTraversal() throws {
        let directory = try ZipTestSupport.directory("7z-tree")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let payload = Data("independent hard link payload\n".utf8)
        let file = source.appendingPathComponent("a-file")
        try payload.write(to: file)
        try FileManager.default.linkItem(at: file, to: source.appendingPathComponent("b-hard"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("c-link").path, withDestinationPath: "a-file")
        for (url, mode) in [(source, 0o755), (source.appendingPathComponent("empty"), 0o750), (file, 0o640)] {
            try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: ZipTestSupport.date], ofItemAtPath: url.path)
        }
        let url = directory.appendingPathComponent("archive.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(contentsOf: source, as: "tree")
        try writer.finish()
        try SevenZipTestSupport.verify(url, expected: [
            .init(name: "tree/", kind: .directory, mode: 0o755),
            .init(name: "tree/a-file", data: payload, mode: 0o640),
            .init(name: "tree/b-hard", data: payload, mode: 0o640),
            .init(name: "tree/c-link", data: Data("a-file".utf8), kind: .symlink, mode: 0o755, date: nil),
            .init(name: "tree/empty/", kind: .directory, mode: 0o750)
        ])
        let bytes = try SevenZipBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.packedSizes.count, 3)
        let attributes = try XCTUnwrap(bytes.fileProperties[0x15])
        XCTAssertEqual(SevenZipTestSupport.uint32(attributes, 2), 0x41ED_8010)
    }

    func testSharedPathValidationAndFailedOutputCleanup() throws {
        let directory = try ZipTestSupport.directory("7z-invalid-paths")
        let paths = ["", "/absolute", "../escape", "a/../b", "a/./b", "a//b", "a\\b", "C:drive", "nul\0name", "file/", String(repeating: "界", count: 22_000)]
        for (index, path) in paths.enumerated() {
            let url = directory.appendingPathComponent("\(index).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            try writer.add(data: Data([1]), as: "valid")
            XCTAssertThrowsError(try writer.add(data: Data(), as: path)) { XCTAssertEqual($0 as? WriterError, .invalidPath(path)) }
            XCTAssertThrowsError(try writer.finish())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertThrowsError(try ArchiveReader.open(url: url))
        }
    }

    func testDuplicateNamesAndFileDirectoryConflicts() throws {
        let directory = try ZipTestSupport.directory("7z-name-conflicts")
        for (index, paths) in [["parent", "parent/child"], ["parent/child", "parent"], ["same", "same"], ["ガラス", "カ\u{3099}ラス"]].enumerated() {
            let url = directory.appendingPathComponent("\(index).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            try writer.add(data: Data(), as: paths[0])
            XCTAssertThrowsError(try writer.add(data: Data(), as: paths[1]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let url = directory.appendingPathComponent("directory.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.addDirectory("same")
        XCTAssertThrowsError(try writer.add(data: Data(), as: "same"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOptionsNoOverwriteAndUnfinishedLifetime() throws {
        let directory = try ZipTestSupport.directory("7z-lifetime")
        let url = directory.appendingPathComponent("archive.7z")
        for options in [WriterOptions(deflateLevel: 10), WriterOptions(preserveOwnerIDs: true), WriterOptions(preserveMacOSMetadata: true)] {
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .sevenZip, options: options))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        do {
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            try writer.add(data: Data([1]), as: "unfinished")
            XCTAssertThrowsError(try ArchiveReader.open(url: url))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        XCTAssertThrowsError(try writer.add(contentsOf: url, as: "self"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let finished = try ArchiveWriter.create(url: url, format: .sevenZip)
        try finished.finish()
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .sevenZip))
        XCTAssertThrowsError(try finished.addDirectory("late"))
        try finished.finish()
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testFailurePreservesReplacementAndInvalidatesOldInode() throws {
        let directory = try ZipTestSupport.directory("7z-replaced-output")
        let url = directory.appendingPathComponent("archive.7z")
        let moved = directory.appendingPathComponent("moved.7z")
        let alias = directory.appendingPathComponent("alias.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(data: Data([1]), as: "valid")
        try FileManager.default.linkItem(at: url, to: alias)
        try FileManager.default.moveItem(at: url, to: moved)
        let replacement = Data("someone else's file".utf8)
        try replacement.write(to: url)
        XCTAssertThrowsError(try writer.add(contentsOf: directory.appendingPathComponent("missing"), as: "missing"))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try Data(contentsOf: moved).count, 0)
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: moved))
        XCTAssertThrowsError(try writer.finish())
    }

    func testPublicTaskCancellationAfterPayloadStartsRemovesOutput() async throws {
        let directory = try ZipTestSupport.directory("7z-cancel")
        let source = directory.appendingPathComponent("large-source")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: source) }
        let url = directory.appendingPathComponent("archive.7z")
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            try writer.add(data: Data("completed first member".utf8), as: "first")
            try writer.add(contentsOf: source, as: "large")
            try writer.finish()
        }
        var observedPayload = false
        for _ in 0..<10_000 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes?[.size] as? NSNumber, size.intValue > 32 {
                observedPayload = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        XCTAssertTrue(observedPayload, "must cancel after a real member payload has been written")
        do { try await task.value; XCTFail("cancelled write succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try ArchiveReader.open(url: url))
        let text = try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-cancelled", success: false)
        XCTAssertTrue(text.contains("No such file or directory"), text)
    }

    func testCancellationBeforeFinishInvalidatesHardLinksAndBeforeCreateLeavesNothing() async throws {
        let directory = try ZipTestSupport.directory("7z-cancel-finish")
        let url = directory.appendingPathComponent("archive.7z")
        let alias = directory.appendingPathComponent("alias.7z")
        let task = Task {
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            try writer.add(data: Data([1, 2, 3]), as: "complete-member")
            try FileManager.default.linkItem(at: url, to: alias)
            withUnsafeCurrentTask { $0?.cancel() }
            try writer.finish()
        }
        do { try await task.value; XCTFail("cancelled finish succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: alias))
        let text = try SevenZipTestSupport.run(["t", alias.path], in: directory, log: "7zz-cancelled-alias", success: false)
        XCTAssertTrue(text.contains("Cannot open the file as archive"), text)
        let beforeCreate = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try ArchiveWriter.create(url: url, format: .sevenZip)
        }
        do { try await beforeCreate.value; XCTFail("cancelled create succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test7zNumberEncodingBoundaries() {
        let cases: [(UInt64, [UInt8])] = [
            (0, [0]), (127, [0x7F]), (128, [0x80, 0x80]), (255, [0x80, 0xFF]),
            (16_383, [0xBF, 0xFF]), (16_384, [0xC0, 0, 0x40]),
            (0xFF_FFFF_FFFF_FFFF, [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            (0x100_0000_0000_0000, [0xFF, 0, 0, 0, 0, 0, 0, 0, 1]),
            (UInt64.max, Array(repeating: 0xFF, count: 9))
        ]
        for (value, expected) in cases { XCTAssertEqual(SevenZipRecords.number(value), Data(expected)) }
    }

    private func smallArchive(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("archive.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
        try writer.add(data: Data("CRC fixture".utf8), as: "file", modificationDate: ZipTestSupport.date)
        try writer.finish()
        return url
    }
}
