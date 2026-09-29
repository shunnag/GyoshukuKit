import Foundation
import CryptoKit
import XCTest
@_spi(ZipRawLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class ZipReencryptionInteropTests: XCTestCase {
    private let old = "interop-old"
    private let new = "interop-new"

    private func directory(_ name: String) throws -> URL {
        let directory = try TestSupport.directory("reencrypt-interop-" + name)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func verify(_ source: URL, _ output: URL, current: String?, password: String?, label: String) throws {
        try ReencryptionSupport.assertStoredEqual(source, output, current: current, password: password)
        let original = try ReencryptionSupport.reader(source, password: current)
        let reader = try ReencryptionSupport.reader(output, password: password)
        try verifyFields(source, output, original: original, result: reader, current: current, password: password)
        for index in original.entries.indices {
            XCTAssertEqual(SHA256.hash(data: try original.read(original.entries[index])),
                           SHA256.hash(data: try reader.read(reader.entries[index])))
        }
        let layouts = try reader.entries.map { try XCTUnwrap(reader.zipRawRecordLayout(at: $0.index)) }
        let aes = layouts.contains { if case .winZipAES = $0.encryption { true } else { false } }
        let methods = Set(layouts.map(\.compressionMethod))
        if methods.contains(20) {
            // 7zz 26.03 は旧 Zstandard 番号を受け付けない。元の fixture も同じ理由で拒否することを確認する。
            for (url, key, suffix) in [(source, current, "-input"), (output, password, "-output")] {
                let log = try EncryptionTestSupport.run(["t", "-p" + (key ?? "unused"), url.path], archive: url, log: label + "-7zz" + suffix, success: false)
                XCTAssertTrue(log.contains("Unsupported Method"), log)
                XCTAssertFalse(log.contains("Headers Error"), log)
            }
        } else {
            try EncryptionTestSupport.run(["t", "-p" + (password ?? "unused"), output.path], archive: output, log: label + "-7zz")
        }
        if !aes && methods.isSubset(of: [0, 8, 9]) {
            try EncryptionTestSupport.run(["-t", "-P", password ?? "unused", output.path], archive: output, log: label + "-unzip", tool: ReferenceTool.unzip)
        } else {
            try EncryptionTestSupport.run(["-l", output.path], archive: output, log: label + "-unzip-list", tool: ReferenceTool.unzip)
        }
        if !aes && methods.isSubset(of: [0, 8, 12, 14]) {
            try EncryptionTestSupport.run(["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); z.setpassword(sys.argv[2].encode('utf-8')); assert z.testzip() is None", output.path, password ?? "unused"],
                archive: output, log: label + "-python", tool: ReferenceTool.python3)
        }
        let listing = try tar(output, arguments: ["-tvf", "-"], label: label + "-tar-list")
        let text = String(decoding: listing, as: UTF8.self)
        for entry in reader.entries { XCTAssertTrue(text.contains(entry.name), text) }
        if methods.isSubset(of: [0, 8]) {
            let files = reader.entries.filter { $0.kind == .file }
            if !files.isEmpty {
                let data = try tar(output, arguments: ["--passphrase", password ?? "unused", "-xOf", "-"] + files.map(\.name), label: label + "-tar-extract")
                let expected = try files.reduce(into: Data()) { $0.append(try reader.read($1)) }
                XCTAssertEqual(data, expected)
            }
        }
    }

    private func verifyFields(_ source: URL, _ output: URL, original: ArchiveReader, result: ArchiveReader,
                              current: String?, password: String?) throws {
        let oldSource = try ArchiveFileSource(url: source), newSource = try ArchiveFileSource(url: output)
        let oldLayout = try ZipUpdateLayout(source: oldSource), newLayout = try ZipUpdateLayout(source: newSource)
        let old = try ZipCentralDirectory.validate(source: oldSource, reader: original, centralOffset: oldLayout.centralOffset, centralSize: oldLayout.centralSize)
        let new = try ZipCentralDirectory.validate(source: newSource, reader: result, centralOffset: newLayout.centralOffset, centralSize: newLayout.centralSize)
        XCTAssertEqual(oldLayout.comment, newLayout.comment)
        for index in original.entries.indices {
            let input = old.records[index].layout, output = new.records[index].layout
            let changed = input.encryption != output.encryption ||
                (output.encryption != .none && current.map { Data($0.utf8) } != password.map { Data($0.utf8) })
            guard changed else { continue }
            let il = try ZipRebuild.LocalHeader(source: oldSource, layout: input)
            let ol = try ZipRebuild.LocalHeader(source: newSource, layout: output)
            let ic = try ZipRebuild.CentralHeader(bytes: old.bytes, range: old.records[index].centralRange)
            let oc = try ZipRebuild.CentralHeader(bytes: new.bytes, range: new.records[index].centralRange)
            XCTAssertFalse(output.hasDataDescriptor)
            XCTAssertEqual(il.name, ol.name); XCTAssertEqual(ic.name, oc.name); XCTAssertEqual(ic.comment, oc.comment)
            XCTAssertEqual(il.fixed.subdata(in: 10..<14), ol.fixed.subdata(in: 10..<14))
            for range in [4..<6, 12..<16, 36..<42] { XCTAssertEqual(ic.fixed.subdata(in: range), oc.fixed.subdata(in: range)) }
            for (before, after, versionPosition, flagsPosition) in [(il.fixed, ol.fixed, 4, 6), (ic.fixed, oc.fixed, 6, 8)] {
                XCTAssertEqual(before.le16(flagsPosition) & ~UInt16(9), after.le16(flagsPosition) & ~UInt16(9))
                XCTAssertEqual(after.le16(flagsPosition) & 9, output.encryption == .none ? 0 : 1)
                let low: UInt16
                if case .winZipAES = output.encryption { low = max(51, before.le16(versionPosition) & 255) }
                else if case .winZipAES = input.encryption {
                    switch input.compressionMethod {
                    case 9: low = 21
                    case 12: low = 46
                    case 14, 19, 20, 93, 95, 97, 98: low = 63
                    default: low = 20
                    }
                } else { low = max(before.le16(versionPosition) & 255, output.encryption == .zipCrypto ? 20 : 0) }
                XCTAssertEqual(after.le16(versionPosition), before.le16(versionPosition) & 0xff00 | low)
            }
            XCTAssertEqual(ol.fixed.le16(8), oc.fixed.le16(10))
            XCTAssertEqual(ol.fixed.le32(14), oc.fixed.le32(16))
            XCTAssertEqual(UInt64(ol.fixed.le32(18)), result.entries[index].compressedSize)
            XCTAssertEqual(UInt64(ol.fixed.le32(22)), result.entries[index].uncompressedSize)
            for (before, after) in [(il.extra, ol.extra), (ic.extra, oc.extra)] {
                let retained = ZipRebuild.extraFields(before).filter { $0.id != 1 && $0.id != 0x9901 }.map { before.subdata(in: $0.range) }
                let fields = ZipRebuild.extraFields(after)
                XCTAssertEqual(fields.filter { $0.id != 1 && $0.id != 0x9901 }.map { after.subdata(in: $0.range) }, retained)
                if case .winZipAES(_, let version) = output.encryption {
                    let aes = try XCTUnwrap(fields.last)
                    var expected = Data([1, 0x99, 7, 0]); expected.le(version)
                    expected.append(contentsOf: [65, 69, 3]); expected.le(input.compressionMethod)
                    XCTAssertEqual(after.subdata(in: aes.range), expected)
                } else { XCTAssertFalse(fields.contains { $0.id == 0x9901 }) }
            }
        }
    }

    /// bsdtar に書庫を stdin から渡し（seek しない読み方）、stdout を返す。
    private func tar(_ archive: URL, arguments: [String], label: String) throws -> Data {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        // AppleDouble を通常 entry として照合し、libarchive の metadata 結合を止める。
        return try ReferenceTool.run(ReferenceTool.bsdtar, ["--options", "zip:!mac-ext"] + arguments,
                                     in: archive.deletingLastPathComponent(), log: label, stdin: input,
                                     environment: [:], standardOutput: label + ".bin").bytes
    }

    func testSevenZipStrengthsMethodsAndAllTargetModes() throws {
        let directory = try directory("7zz")
        let input = directory.appendingPathComponent("payload")
        try Data(String(repeating: "ZIP interoperability payload 0123456789\n", count: 700).utf8).write(to: input)
        for method in ["Copy", "Deflate", "Deflate64", "BZip2", "LZMA"] {
            for encryption in ["none", "ZipCrypto", "AES128", "AES192", "AES256"] {
                let label = "\(method)-\(encryption)"
                let source = directory.appendingPathComponent(label + ".zip")
                let current = encryption == "none" ? nil : old
                let flags = current == nil ? [] : ["-p" + old, "-mem=" + encryption]
                try EncryptionTestSupport.run(["a", "-tzip", "-mm=" + method] + flags + [source.path, input.path], archive: source, log: label + "-create")
                for mode in 0..<3 {
                    let output = directory.appendingPathComponent(label + "-\(mode).zip")
                    let password = mode == 0 ? nil : new
                    try ReencryptionSupport.convert(source, to: output, current: current, password: password, encryption: mode == 1 ? .zipCrypto : .aes256)
                    try verify(source, output, current: current, password: password, label: label + "-\(mode)")
                }
            }
        }
    }

    func testWriterCorpusInfoZIPAndDitto() throws {
        let directory = try directory("producers")
        for method in [CompressionMethod.stored, .deflate] {
            for sourceMode in 0..<3 {
                let source = try ReencryptionSupport.fixture(directory, name: "gk-\(method)-\(sourceMode).zip", password: sourceMode == 0 ? nil : old,
                    encryption: sourceMode == 1 ? .zipCrypto : .aes256, method: method, special: true)
                for mode in 0..<3 {
                    let output = directory.appendingPathComponent("gk-\(method)-\(sourceMode)-\(mode).zip")
                    try ReencryptionSupport.convert(source, to: output, current: sourceMode == 0 ? nil : old,
                        password: mode == 0 ? nil : new, encryption: mode == 1 ? .zipCrypto : .aes256)
                    try verify(source, output, current: sourceMode == 0 ? nil : old, password: mode == 0 ? nil : new, label: "gk-\(method)-\(sourceMode)-\(mode)")
                }
            }
        }
        let input = directory.appendingPathComponent("info-file")
        try Data(String(repeating: "Info-ZIP descriptor\n", count: 50).utf8).write(to: input)
        let link = directory.appendingPathComponent("info-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "info-file")
        let infozip = directory.appendingPathComponent("infozip.zip")
        try EncryptionTestSupport.run(["-e", "-y", "-P", old, "-j", infozip.path, input.path, link.path], archive: infozip, log: "infozip-create", tool: ReferenceTool.zip)
        let info = try ReencryptionSupport.reader(infozip)
        XCTAssertTrue(try XCTUnwrap(info.zipRawRecordLayout(at: 0)).hasDataDescriptor)
        let folder = directory.appendingPathComponent("ditto-input")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file")
        try Data("ditto payload".utf8).write(to: file)
        try Data("resource-fork-payload".utf8).write(to: URL(fileURLWithPath: file.path + "/..namedfork/rsrc"))
        let ditto = directory.appendingPathComponent("ditto.zip")
        try EncryptionTestSupport.run(["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, ditto.path], archive: ditto, log: "ditto-create", tool: ReferenceTool.ditto)
        XCTAssertTrue(try ReencryptionSupport.reader(ditto).entries.contains { $0.name.contains("__MACOSX/") && $0.kind == .file })
        for (label, source, current) in [("infozip", infozip, Optional(old)), ("ditto", ditto, nil)] {
            for mode in 0..<3 {
                let output = directory.appendingPathComponent(label + "-\(mode).zip")
                try ReencryptionSupport.convert(source, to: output, current: current, password: mode == 0 ? nil : new,
                    encryption: mode == 1 ? .zipCrypto : .aes256)
                try verify(source, output, current: current, password: mode == 0 ? nil : new, label: label + "-\(mode)")
            }
        }
    }

    func testModernFixturesAndSamePasswordMethodChanges() throws {
        let directory = try directory("modern")
        let root = TestPaths.fixtures.appendingPathComponent("zip-modern")
        for name in ["xz", "xz-aes", "xz-zipcrypto", "zstd20", "zstd93", "zstd-aes20", "zstd-aes93"] {
            let encoded = try Data(contentsOf: root.appendingPathComponent(name + ".zip.b64"))
            let source = directory.appendingPathComponent(name + ".zip")
            try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: source)
            for mode in 0..<3 {
                let output = directory.appendingPathComponent(name + "-\(mode).zip")
                try ReencryptionSupport.convert(source, to: output, current: "KaitoFixture", password: mode == 0 ? nil : "KaitoFixture",
                    encryption: mode == 1 ? .zipCrypto : .aes256)
                try verify(source, output, current: "KaitoFixture", password: mode == 0 ? nil : "KaitoFixture", label: name + "-\(mode)")
            }
        }
    }

    func testMixedPlainAndAESRetainsOnlyMatchingRecords() throws {
        let directory = try directory("mixed")
        let source = try ReencryptionSupport.fixture(directory, password: old, items: [("encrypted", Data([1]))])
        let append = try ArchiveUpdater.open(url: source)
        try append.add(data: Data([2]), as: "plain", modificationDate: TestSupport.date)
        try append.commit()
        let original = try EncryptionTestSupport.localRecords(source)
        let output = directory.appendingPathComponent("out.zip")
        try ReencryptionSupport.convert(source, to: output, current: old, password: old)
        XCTAssertEqual(try EncryptionTestSupport.localRecords(output)["encrypted"], original["encrypted"])
        try verify(source, output, current: old, password: old, label: "mixed")
    }

    func testUTF8AndCanonicallyEquivalentPasswordsWithReferenceTools() throws {
        let directory = try directory("password-utf8")
        let nfc = "日本語-caf\u{e9}", nfd = "日本語-cafe\u{301}"
        let source = try ReencryptionSupport.fixture(directory, password: nfc)
        for mode in [ZipEncryption.aes256, .zipCrypto] {
            let output = directory.appendingPathComponent("\(mode).zip")
            try ReencryptionSupport.convert(source, to: output, current: nfc, password: nfd, encryption: mode)
            try verify(source, output, current: nfc, password: nfd, label: "utf8-\(mode)")
        }
    }
}
