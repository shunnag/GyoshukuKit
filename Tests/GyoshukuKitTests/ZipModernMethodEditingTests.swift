import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipModernMethodEditingTests: XCTestCase {
    private let fixtures = ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd20.zip", "zstd93.zip",
                            "zstd-aes20.zip", "zstd-aes93.zip"]
    private let password = "KaitoFixture"
    private let payload = Data(String(repeating: "XZ and Zstandard ZIP interoperability 日本語\n", count: 800).utf8)

    private func fixture(_ name: String, below directory: URL) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KaitoKit/Tests/Fixtures/zip-modern")
        let encoded = try Data(contentsOf: root.appendingPathComponent(name + ".b64"))
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: url)
        return url
    }

    func testAppendPreservesXZAndLegacyZstandardLocalRecords() throws {
        let directory = try ZipTestSupport.directory("modern-method-append")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in fixtures {
            let url = try fixture(name, below: directory)
            let before = try Data(contentsOf: url)
            let original = try ArchiveReader.open(url: url)
            let entry = try XCTUnwrap(original.entries.first)
            let record = try XCTUnwrap(original.rawRecord(of: entry))
            let updater = try ArchiveUpdater.open(url: url)
            try updater.add(data: Data("added".utf8), as: "added.txt")
            try updater.commit()
            let after = try Data(contentsOf: url)
            XCTAssertEqual(slice(after, record.recordRange), slice(before, record.recordRange), name)
            try assertContents(url, names: ["payload.txt", "added.txt"], original: entry)
        }
    }

    func testRenameAndRemovePreserveCompressedAndEncryptedPayloads() throws {
        let directory = try ZipTestSupport.directory("modern-method-rename")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in fixtures {
            let url = try fixture(name, below: directory)
            let initial = try ArchiveUpdater.open(url: url)
            try initial.add(data: Data("remove me".utf8), as: "remove.txt")
            try initial.commit()
            let before = try Data(contentsOf: url)
            let original = try ArchiveReader.open(url: url)
            let entry = try XCTUnwrap(original.entries.first)
            let record = try XCTUnwrap(original.rawRecord(of: entry))
            let updater = try ArchiveUpdater.open(url: url)
            try updater.rename(entryAt: 0, to: "改名したファイル.txt")
            try updater.remove(entriesAt: [1])
            try updater.commit()
            let reader = try ArchiveReader.open(url: url)
            let moved = try XCTUnwrap(reader.rawRecord(of: reader.entries[0]))
            XCTAssertEqual(slice(try Data(contentsOf: url), moved.payloadRange), slice(before, record.payloadRange), name)
            try assertContents(url, names: ["改名したファイル.txt"], original: entry)
        }
    }

    private func assertContents(_ url: URL, names: [String], original: ArchiveEntry) throws {
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), names)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.methodDescription, original.methodDescription)
        XCTAssertEqual(entry.formatSpecific["method"], original.formatSpecific["method"])
        XCTAssertEqual(entry.isEncrypted, original.isEncrypted)
        XCTAssertEqual(entry.compressedSize, original.compressedSize)
        XCTAssertEqual(entry.crc32, original.crc32)
        XCTAssertEqual(try reader.read(entry), payload)
        if reader.entries.count > 1 {
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("added".utf8))
            XCTAssertEqual(reader.entries[1].methodDescription, "deflate")
        }
    }

    private func slice(_ bytes: Data, _ range: Range<UInt64>) -> Data {
        bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}
