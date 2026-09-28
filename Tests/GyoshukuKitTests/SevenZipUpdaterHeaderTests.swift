import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterHeaderTests: XCTestCase {
    func testAllHeaderPolicies() throws {
        let root = try ZipTestSupport.directory("7z-header-policies")
        for name in ["g_plain", "g_aesh", "z_plainhdr", "z_default", "z_aesonlyh", "z_aesh", "z_aeshdirs"] {
            let source = SevenZipEditSupport.fixture(name)
            let model = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(source)))
            for encrypted in [false, true] {
                let output = root.appendingPathComponent("\(name)-\(encrypted).7z")
                let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output,
                    options: WriterOptions(password: "new", encryptsSevenZipHeaders: encrypted))
                try updater.reencryptExistingEntries(currentPassword: "secret")
                try updater.commit()
                let actual = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(output, password: "new")))
                XCTAssertEqual(actual.header.encrypted, encrypted)
                XCTAssertEqual(actual.header.compressed, model.header.compressed)
                if encrypted { XCTAssertThrowsError(try SevenZipEditSupport.reader(output, password: nil)) }
                if name == "z_aeshdirs" { XCTAssertEqual(updater.lastCommitStrategy, .headerOnly) }
                try SevenZipExternalOracles.check(output, password: "new")
            }
        }
    }

    func testNeverSilentlyDecryptHeaders() throws {
        let root = try ZipTestSupport.directory("7z-header-safety")
        for add in [false, true] {
            let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
            let updater = try SevenZipUpdater.open(url: SevenZipEditSupport.fixture("g_aesh"), password: "secret", output: output)
            if add { try updater.add(data: Data([1]), as: "addition") }
            XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? WriterError, .invalidOption("encryptsSevenZipHeaders")) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }

    func testOversizedMetadataFailsAndCleansExistingAppend() throws {
        let root = try ZipTestSupport.directory("7z-metadata-limit"), source = root.appendingPathComponent("source.7z")
        let writer = try ArchiveWriter.create(url: source, format: .sevenZip)
        for index in 0..<512 { try writer.addDirectory("dir-\(index)", modificationDate: ZipTestSupport.date, ownerIDs: nil) }
        try writer.finish()
        let original = try Data(contentsOf: source)
        for add in [false, true] {
            let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            if add { try updater.add(data: Data([7]), as: "added") }
            for index in 0..<512 { try updater.rename(entryAt: index, to: String(repeating: "a", count: 16384) + "\(index)") }
            XCTAssertThrowsError(try updater.commit()) {
                guard case RewriterError.unrepresentable = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }

    func testAttributeLessSourceAddsExecutableAndDirectoryWithoutAttributes() throws {
        let root = try ZipTestSupport.directory("7z-absent-attributes")
        for name in ["solid_zero", "zero_lzma2"] {
            let source = SevenZipEditSupport.fixture(name), reader = try SevenZipEditSupport.reader(source)
            let original = try XCTUnwrap(SevenZipEditModel.read(reader))
            var expected = try SevenZipEditSupport.items(reader)
            XCTAssertFalse(original.files.isEmpty)
            XCTAssertTrue(original.files.allSatisfy { $0.attributes == nil && $0.modificationTime == nil })
            let output = root.appendingPathComponent(name + ".7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            if name == "solid_zero" {
                let deleted = try XCTUnwrap(reader.entries.firstIndex { ($0.uncompressedSize ?? 0) > 0 })
                try updater.remove(entriesAt: [deleted])
                expected.remove(at: deleted)
            }
            try updater.add(data: Data([1, 7, 5]), as: "added.txt", modificationDate: ZipTestSupport.date, permissions: 0o755)
            try updater.addDirectory("added-dir", modificationDate: ZipTestSupport.date, ownerIDs: nil)
            try updater.commit()
            let actual = try SevenZipEditSupport.reader(output)
            XCTAssertEqual(Array(try SevenZipEditSupport.items(actual).dropLast(2)), expected)
            let model = try XCTUnwrap(SevenZipEditModel.read(actual))
            XCTAssertFalse(model.filePropertyOrder.contains(0x15))
            XCTAssertTrue(model.files.allSatisfy { $0.attributes == nil })
            XCTAssertEqual(model.files.suffix(2).map(\.modificationTime), Array(repeating: try SevenZipRecords.timestamp(ZipTestSupport.date), count: 2))
            XCTAssertEqual(actual.entries.last?.kind, .directory)
            XCTAssertFalse(model.files.last!.isEmptyFile)
            XCTAssertFalse(model.files.last!.hasStream)
            XCTAssertEqual(try actual.read(actual.entries[actual.entries.count - 2]), Data([1, 7, 5]))
            try SevenZipExternalOracles.check(output, password: nil)
            if SevenZipExternalOracles.available {
                let listing = try ZipTestSupport.run(ReferenceTool.sevenZip, ["l", output.path], in: root, log: name + "-list")
                let directory = try XCTUnwrap(listing.components(separatedBy: "\n").first { $0.hasSuffix("  added-dir/") })
                XCTAssertTrue(directory.contains(" D.... "), directory)
            }
        }
    }

    func testEmptyAndAttributeBearingSourcesKeepAddedMode() throws {
        let root = try ZipTestSupport.directory("7z-added-attributes")
        for name in ["empty_fi0", "g_plain"] {
            let output = root.appendingPathComponent(name + ".7z")
            let updater = try SevenZipUpdater.open(url: SevenZipEditSupport.fixture(name), output: output)
            try updater.add(data: Data([7]), as: "added", modificationDate: ZipTestSupport.date, permissions: 0o755)
            try updater.commit()
            let reader = try SevenZipEditSupport.reader(output)
            let model = try XCTUnwrap(SevenZipEditModel.read(reader))
            XCTAssertEqual(model.files.last?.attributes, UInt32(0o100755) << 16 | 0x8020)
            XCTAssertEqual(reader.entries.last?.posixPermissions, 0o755)
            try SevenZipExternalOracles.check(output, password: nil)
        }
    }

    func testFrozenEmptySevenZipAdditionHeaderModel() throws {
        // KaitoKit 4eaf915 rejects this valid 32 B empty input (P5 risk 11). Exercise its
        // empty model's addition/serialization here; the public open refusal stays covered.
        let input = try Data(contentsOf: SevenZipEditSupport.fixture("empty_7zz"))
        XCTAssertEqual(input, SevenZipRecords.signature(packedSize: 0, header: Data()))
        let empty = SevenZipEditModel(), data = Data([7, 2, 4])
        let encoded = try LZMA2Compressor.encode(data)
        var record = SevenZipRecords.Entry(name: "added", mode: 0o100755, size: UInt64(data.count),
                                           mtime: try SevenZipRecords.timestamp(ZipTestSupport.date))
        record.properties = encoded.properties; record.crc = CRC32.checksum(data)
        record.compressedSize = UInt64(encoded.payload.count); record.packedSize = record.compressedSize
        let plan = SevenZipEditPlan.make(model: empty, filesByFolder: [], names: [], removed: [], renamed: [:],
            additions: 1, reencrypt: false, currentPassword: nil, headerPassword: nil, options: WriterOptions())
        let model = try plan.assemble(original: empty, filesByFolder: [], replacements: [:],
            additions: [.init(record: record, packRange: 32..<(32 + record.packedSize))]).model
        XCTAssertEqual(model.files[0].attributes, UInt32(0o100755) << 16 | 0x8020)
        let header = try SevenZipHeaderSerializer.header(model)
        let root = try ZipTestSupport.directory("7z-empty-32-add-model"), output = root.appendingPathComponent("output.7z")
        try (SevenZipRecords.signature(packedSize: record.packedSize, header: header) + encoded.payload + header).write(to: output)
        let reader = try SevenZipEditSupport.reader(output)
        XCTAssertEqual(try reader.read(reader.entries[0]), data)
        XCTAssertEqual(reader.entries[0].posixPermissions, 0o755)
        try SevenZipExternalOracles.check(output, password: nil)
    }
}
