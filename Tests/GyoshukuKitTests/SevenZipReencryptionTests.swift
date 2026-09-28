import Foundation
import CryptoKit
import Synchronization
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipReencryptionTests: XCTestCase {
    func testFixtureSetChangeRemoveAndCarryBytes() throws {
        let root = try TestSupport.directory("7z-reencrypt-fixtures")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            SevenZipEditSupport.fixtures.appendingPathComponent("expected-decrypted.json"))) as? [String: Any])
        let expectedDecrypted = try XCTUnwrap(json["archives"] as? [String: [[String: Any]]])
        for name in ["g_plain", "g_aes", "g_aesh", "z_default", "z_aes", "z_aesh", "m", "z_aeshdirs", "copyaes"] {
            let source = SevenZipEditSupport.fixture(name)
            let oldReader = try SevenZipEditSupport.reader(source)
            let old = try XCTUnwrap(SevenZipEditModel.read(oldReader))
            let items = try SevenZipEditSupport.items(oldReader)
            let originalPacks = try old.folders.indices.map { try compressedPlaintext(oldReader, model: old, index: $0, url: source) }
            for vector in expectedDecrypted[name + ".7z"] ?? [] where vector["scope"] as? String == "main" {
                let index = try XCTUnwrap(vector["folderIndex"] as? Int)
                XCTAssertEqual(originalPacks[index].count, vector["plaintextLength"] as? Int)
                XCTAssertEqual(SHA256.hash(data: originalPacks[index]).map { String(format: "%02x", $0) }.joined(), vector["plaintextSHA256"] as? String)
            }
            for password: String? in ["changed", nil] {
                for sequential in [false, true] {
                    let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                    let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                        try SevenZipUpdater.open(url: source, password: "secret", output: output,
                            options: WriterOptions(password: password, encryptsSevenZipHeaders: password != nil && old.header.encrypted))
                    }
                    try updater.reencryptExistingEntries(currentPassword: "secret")
                    try updater.commit()
                    let reader = try SevenZipEditSupport.reader(output, password: password)
                    XCTAssertEqual(try SevenZipEditSupport.items(reader), items, "\(name) \(password != nil) \(sequential)")
                    let new = try XCTUnwrap(SevenZipEditModel.read(reader))
                    XCTAssertTrue(new.folders.allSatisfy { $0.isEncrypted == (password != nil) })
                    for index in new.folders.indices {
                        XCTAssertEqual(try compressedPlaintext(reader, model: new, index: index, url: output), originalPacks[index])
                        let size = UInt64(originalPacks[index].count)
                        XCTAssertEqual(new.packs[new.folders[index].packIndices.lowerBound].length,
                                       password == nil ? size : (size + 15) / 16 * 16)
                    }
                    if password != nil && !new.folders.isEmpty {
                        reader.password = "secret"
                        let entry = try XCTUnwrap(reader.entries.first { $0.isEncrypted && ($0.uncompressedSize ?? 0) > 0 })
                        XCTAssertThrowsError(try reader.read(entry), name)
                    }
                    if password == nil && (name == "g_aes" || name == "g_aesh") {
                        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: SevenZipEditSupport.fixture("g_plain")), name)
                    }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["output.7z"])
                    try SevenZipExternalOracles.check(output, password: password)
                }
            }
        }
    }

    func testFixedIVAttachmentMatchesWriter() throws {
        let root = try TestSupport.directory("7z-reencrypt-fixed-iv")
        let plain = try SevenZipEditSupport.source(root)
        for headers in [false, true] {
            let makeIV: @Sendable () -> Data = { Data(repeating: 0xA5, count: 16) }
            let other = try SevenZipEditSupport.work(root)
            let encrypted = try SevenZipAESEncryptor.$testingIV.withValue(makeIV) {
                try SevenZipEditSupport.source(other, password: "secret", headers: headers)
            }
            let output = other.appendingPathComponent("converted.7z")
            try SevenZipAESEncryptor.$testingIV.withValue(makeIV) {
                let updater = try SevenZipUpdater.open(url: plain, output: output,
                    options: WriterOptions(password: "secret", encryptsSevenZipHeaders: headers))
                try updater.reencryptExistingEntries(currentPassword: nil)
                try updater.commit()
            }
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: encrypted))
        }
    }

    func testPasswordFailuresAndMixedPasswords() throws {
        let root = try TestSupport.directory("7z-reencrypt-passwords")
        for (name, password): (String, String?) in [("g_aes", "wrong"), ("g_aes", nil), ("mix", "secret"), ("mix", "secret2"), ("copyaes", "wrong")] {
            for target: String? in [nil, "new"] {
                let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                let updater = try SevenZipUpdater.open(url: SevenZipEditSupport.fixture(name), password: "secret", output: output,
                                                      options: WriterOptions(password: target))
                try updater.reencryptExistingEntries(currentPassword: password)
                XCTAssertThrowsError(try updater.commit(), name) {
                    XCTAssertEqual($0 as? KaitoError, password == nil ? .passwordRequired : .wrongPassword, name)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
            }
        }
    }

    func testPartialEncryptionAndOperationsAfterAdd() throws {
        let root = try TestSupport.directory("7z-partial-encryption")
        let source = try SevenZipEditSupport.source(root)
        let mixed = root.appendingPathComponent("mixed.7z")
        let add = try SevenZipUpdater.open(url: source, output: mixed, options: WriterOptions(password: "secret"))
        try add.add(data: Data([4, 9]), as: "secret", modificationDate: TestSupport.date); try add.commit()
        let initial = try SevenZipEditSupport.reader(mixed)
        XCTAssertEqual(initial.entries.filter(\.isEncrypted).count, 1)
        var expected = try SevenZipEditSupport.items(initial)
        let output = root.appendingPathComponent("converted.7z")
        let update = try SevenZipUpdater.open(url: mixed, password: "unused", output: output, options: WriterOptions(password: "new"))
        try update.add(data: Data([8]), as: "new", modificationDate: TestSupport.date)
        expected.append(.init(name: "new", kind: .file, data: Data([8])))
        try update.remove(entriesAt: [0]); expected.remove(at: 0)
        try update.reencryptExistingEntries(currentPassword: "secret")
        try update.commit()
        XCTAssertEqual(try SevenZipEditSupport.items(SevenZipEditSupport.reader(output, password: "new")), expected)
        XCTAssertEqual(update.lastCommitStrategy, .relocatedAppend)
        try SevenZipExternalOracles.check(output, password: "new")
    }
    func testLargeAESCopyWrongPasswordLimitAndSolidCurrentPassword() throws {
        let root = try TestSupport.directory("7z-aes-copy-limit")
        let source = SevenZipEditSupport.fixture("copyaes")
        let input = try SevenZipEditSupport.reader(source)
        let small = input.entries.first { ($0.uncompressedSize ?? 0) <= 65536 }!.index
        let largeOnly = root.appendingPathComponent("large.7z")
        let drop = try SevenZipUpdater.open(url: source, password: "secret", output: largeOnly,
                                           options: WriterOptions(password: "secret"))
        try drop.remove(entriesAt: [small]); try drop.commit()
        let wrong = root.appendingPathComponent("wrong.7z")
        let change = try SevenZipUpdater.open(url: largeOnly, output: wrong, options: WriterOptions(password: "new"))
        try change.reencryptExistingEntries(currentPassword: "wrong")
        try change.commit()
        let broken = try SevenZipEditSupport.reader(wrong, password: "new")
        XCTAssertThrowsError(try broken.read(broken.entries[0]))
        // 64 KiB を越える AES + Copy の鍵は先頭 probe だけでは検出できない。
        let solid = SevenZipEditSupport.fixture("z_aes")
        let original = try SevenZipEditSupport.reader(solid)
        let expected = try SevenZipEditSupport.items(original)
        let model = try XCTUnwrap(SevenZipEditModel.read(original))
        let index = model.filesByFolder.first { $0.count > 1 }!.first!
        let output = root.appendingPathComponent("solid.7z")
        let updater = try SevenZipUpdater.open(url: solid, password: "wrong", output: output, options: WriterOptions(password: "new"))
        try updater.remove(entriesAt: [index])
        try updater.reencryptExistingEntries(currentPassword: "secret")
        try updater.add(data: Data([9]), as: "new")
        try updater.commit()
        XCTAssertEqual(try SevenZipEditSupport.items(SevenZipEditSupport.reader(output, password: "new")),
                       expected.enumerated().filter { $0.offset != index }.map(\.element) + [.init(name: "new", kind: .file, data: Data([9]))])
        try SevenZipExternalOracles.check(output, password: "new")
    }

    private func compressedPlaintext(_ reader: ArchiveReader, model: SevenZipEditModel, index: Int, url: URL) throws -> Data {
        if model.folders[index].isEncrypted {
            let stream = try reader.sevenZipDecryptedPackedStream(folder: index, packedInput: 0)
            var result = Data()
            while true {
                let chunk = try stream.readSome(upTo: 256 * 1024)
                if chunk.isEmpty { return result }; result.append(chunk)
            }
        }
        let bytes = try Data(contentsOf: url), range = model.packs[model.folders[index].packIndices.lowerBound].range
        return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

}
