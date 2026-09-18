import Foundation
import Darwin
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class EncryptionTests: XCTestCase {
    private let password = EncryptionTestSupport.password

    func testZipAESBoundaryFilesHeadersAndOracles() throws {
        try checkZip(encryption: .aes256, label: "aes")
    }

    func testZipCryptoBoundaryFilesHeadersAndOracles() throws {
        try checkZip(encryption: .zipCrypto, label: "zipcrypto")
    }

    private func checkZip(encryption: ZipEncryption, label: String) throws {
        let directory = try ZipTestSupport.directory("encryption-\(label)")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url, options: WriterOptions(password: password, zipEncryption: encryption))
        try EncryptionTestSupport.writeCorpus(writer, in: directory)
        XCTAssertTrue(try EncryptionTestSupport.spoolFiles(in: directory).isEmpty)
        try writer.finish()
        let items = EncryptionTestSupport.corpus
        let reader = try EncryptionTestSupport.verify(url, items: items) { $0.kind == .file }
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        var central = bytes.central
        for (entry, item) in zip(reader.entries, items) {
            let local = Int(bytes.u32(central + 42))
            let encrypted = item.kind == .file
            let aes = encrypted && encryption == .aes256
            let method: UInt16 = item.kind != .file || item.data.isEmpty || item.name.hasSuffix(".jpg") ? 0 : 8
            let crc: UInt32 = aes && item.data.count >= 20 ? 0 : CRC32.checksum(item.data)
            XCTAssertEqual(bytes.u16(local + 6), encrypted ? 0x0801 : 0x0800)
            XCTAssertEqual(bytes.u16(central + 8), bytes.u16(local + 6))
            XCTAssertEqual(bytes.u16(local + 8), aes ? 99 : method)
            XCTAssertEqual(bytes.u16(central + 10), bytes.u16(local + 8))
            XCTAssertEqual(bytes.u16(local + 4), aes ? 51 : 20)
            XCTAssertEqual(bytes.u16(central + 6), bytes.u16(local + 4))
            XCTAssertEqual(bytes.u32(local + 14), crc)
            XCTAssertEqual(bytes.u32(central + 16), crc)
            XCTAssertEqual(bytes.u32(local + 18), bytes.u32(central + 20))
            if method == 0 {
                XCTAssertEqual(Int(bytes.u32(local + 18)), item.data.count + (encrypted ? (aes ? 28 : 12) : 0))
            }
            if aes {
                let localExtra = try XCTUnwrap(bytes.extras(local, local: true)[0x9901])
                let centralExtra = try XCTUnwrap(bytes.extras(central, local: false)[0x9901])
                XCTAssertEqual(localExtra, centralExtra)
                for extra in [localExtra, centralExtra] {
                    XCTAssertEqual(extra.count, 7)
                    XCTAssertEqual(ZipBytes(data: extra).u16(0), item.data.count < 20 ? 1 : 2)
                    XCTAssertEqual(Array(extra[2..<5]), [0x41, 0x45, 3])
                    XCTAssertEqual(ZipBytes(data: extra).u16(5), method)
                }
            } else {
                XCTAssertNil(bytes.extras(local, local: true)[0x9901])
                XCTAssertNil(bytes.extras(central, local: false)[0x9901])
            }
            let raw = try XCTUnwrap(reader.rawRecord(of: entry))
            XCTAssertEqual(raw.payloadRange.upperBound, raw.recordRange.upperBound, "must not write a descriptor")
            central += 46 + Int(bytes.u16(central + 28)) + Int(bytes.u16(central + 30)) + Int(bytes.u16(central + 32))
        }
        try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-t")
        let listing = try EncryptionTestSupport.run(["l", "-slt", "-p" + password, url.path], archive: url, log: "7zz-list")
        XCTAssertTrue(listing.contains("Method = \(encryption == .aes256 ? "AES-256" : "ZipCrypto") Deflate"), listing)
        XCTAssertTrue(listing.contains("Method = \(encryption == .aes256 ? "AES-256" : "ZipCrypto") Store"), listing)
        let listed = SevenZipTestSupport.listingEntries(listing)
        let encryptionName = encryption == .aes256 ? "AES-256" : "ZipCrypto"
        XCTAssertEqual(listed.first { $0["Path"] == "deflated.txt" }?["Method"], encryptionName + " Deflate")
        XCTAssertEqual(listed.first { $0["Path"] == "stored.jpg" }?["Method"], encryptionName + " Store")
        if encryption == .aes256 {
            let wrong = try ArchiveReader.open(url: url, options: ReaderOptions(password: "wrong password"))
            for entry in wrong.entries where entry.kind == .file {
                XCTAssertThrowsError(try wrong.read(entry)) {
                    guard case KaitoError.wrongPassword = $0 else { return XCTFail("\($0)") }
                }
            }
        }
        try EncryptionTestSupport.run(["t", "-pwrong-password", url.path], archive: url, log: "7zz-wrong", success: false)
        if encryption == .zipCrypto {
            try EncryptionTestSupport.run(["-P", password, "-t", url.path], archive: url, log: "unzip-t", tool: "/usr/bin/unzip")
        }
        XCTAssertTrue(try EncryptionTestSupport.spoolFiles(in: directory).isEmpty)
    }

    func testZipAESOddChunkBoundariesAndAuthentication() throws {
        let directory = try ZipTestSupport.directory("encryption-aes-chunks")
        let source = directory.appendingPathComponent("source")
        let data = Data((0..<600_037).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        try data.write(to: source)
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url, options: WriterOptions(compressionMethod: .stored, password: password))
        var calls = 0
        let sizes = [1, 15, 16, 17, 65_539, 131_071]
        try writer.add(contentsOf: source, as: "odd.bin") { input, requested in
            defer { calls += 1 }
            return try input.read(upToCount: min(requested, sizes[calls % sizes.count])) ?? Data()
        }
        try writer.finish()
        let reader = try EncryptionTestSupport.verify(url, items: [.init(name: "odd.bin", data: data)]) { _ in true }
        try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-t")
        let raw = try XCTUnwrap(reader.rawRecord(of: reader.entries[0]))
        let original = try Data(contentsOf: url)
        for (label, offset) in [("ciphertext", Int(raw.payloadRange.lowerBound) + 18 + 19),
                                ("authentication", Int(raw.payloadRange.upperBound) - 1)] {
            var corrupt = original
            corrupt[offset] ^= 1
            let damaged = directory.appendingPathComponent(label + ".zip")
            try corrupt.write(to: damaged)
            let rejected = try ArchiveReader.open(url: damaged, options: ReaderOptions(password: password))
            XCTAssertThrowsError(try rejected.read(rejected.entries[0])) {
                guard case KaitoError.wrongPassword = $0 else { return XCTFail("\($0)") }
            }
            try EncryptionTestSupport.run(["t", "-p" + password, damaged.path], archive: damaged,
                                          log: "7zz-" + label, success: false)
        }
    }

    func testSevenZipAESWithAndWithoutEncryptedHeaders() throws {
        let name = "private-inventory-2026-秘密.txt"
        let data = Data(repeating: 0x79, count: 1024 * 1024 + 21)
        for headers in [false, true] {
            let directory = try ZipTestSupport.directory("encryption-7z-headers-\(headers)")
            let url = directory.appendingPathComponent("archive.7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                options: WriterOptions(password: password, encryptsSevenZipHeaders: headers))
            try writer.add(data: data, as: name)
            try writer.add(data: Data(), as: "empty")
            try writer.addDirectory("directory")
            try writer.add(data: Data([1, 2, 3, 4, 5]), as: "tiny")
            try writer.finish()
            let items: [EncryptionTestSupport.Item] = [.init(name: name, data: data), .init(name: "empty"),
                .init(name: "directory/", kind: .directory), .init(name: "tiny", data: Data([1, 2, 3, 4, 5]))]
            try EncryptionTestSupport.verify(url, items: items) { !$0.data.isEmpty }
            try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-t")
            let listing = try EncryptionTestSupport.run(["l", "-slt", "-p" + password, url.path], archive: url, log: "7zz-list")
            XCTAssertTrue(listing.contains("7zAES"), listing)
            let raw = try Data(contentsOf: url)
            let header = try EncryptedSevenZipHeader(raw)
            XCTAssertEqual(header.encoded, headers)
            for (index, folder) in header.folders.enumerated() {
                XCTAssertEqual(folder.methods, headers ? [[0x06, 0xF1, 0x07, 0x01]] : [[0x06, 0xF1, 0x07, 0x01], [0x21]])
                XCTAssertEqual(folder.properties[0].count, 18)
                XCTAssertEqual(Array(folder.properties[0].prefix(2)), [0x53, 0x0F])
                XCTAssertEqual(header.packedSizes[index] % 16, 0)
                XCTAssertEqual(header.packedSizes[index], (folder.unpackSizes[0] + 15) & ~UInt64(15))
                if !headers {
                    XCTAssertEqual(folder.binds.count, 1)
                    XCTAssertEqual(folder.binds[0].0, 1)
                    XCTAssertEqual(folder.binds[0].1, 0)
                    XCTAssertEqual(folder.unpackSizes.last, index == 0 ? UInt64(data.count) : 5)
                }
            }
            if headers {
                XCTAssertGreaterThan(header.packOffset, 0)
                XCTAssertNil(raw.range(of: Data(name.utf8)))
                XCTAssertNil(raw.range(of: try XCTUnwrap(name.data(using: .utf16LittleEndian))))
                let noPassword = try EncryptionTestSupport.run(["l", url.path], archive: url, log: "7zz-no-password", success: false)
                XCTAssertFalse(noPassword.contains(name))
                XCTAssertThrowsError(try ArchiveReader.open(url: url))
            } else {
                XCTAssertEqual(header.packOffset, 0)
                XCTAssertNotNil(raw.range(of: try XCTUnwrap(name.data(using: .utf16LittleEndian))))
                let noPassword = try EncryptionTestSupport.run(["l", url.path], archive: url, log: "7zz-no-password")
                XCTAssertTrue(noPassword.contains(name))
                XCTAssertNotEqual(header.folders[0].properties[0], header.folders[1].properties[0])
            }
            XCTAssertThrowsError(try {
                let wrong = try ArchiveReader.open(url: url, options: ReaderOptions(password: "wrong"))
                return try wrong.read(wrong.entries[0])
            }())
            try EncryptionTestSupport.run(["t", "-pwrong", url.path], archive: url, log: "7zz-wrong", success: false)
        }
    }

    func testSevenZipFolderGraphMatches7zzReference() throws {
        let directory = try ZipTestSupport.directory("encryption-7z-reference")
        let source = directory.appendingPathComponent("file.txt")
        try Data(repeating: 0x41, count: 8192).write(to: source)
        let reference = directory.appendingPathComponent("reference.7z")
        try EncryptionTestSupport.run(["a", "-t7z", "-p" + password, "-mhe=off", "-mhc=off", reference.path, source.path],
                                      archive: reference, log: "7zz-create")
        let url = directory.appendingPathComponent("writer.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: WriterOptions(password: password))
        try writer.add(contentsOf: source, as: "file.txt")
        try writer.finish()
        let actual = try EncryptedSevenZipHeader(Data(contentsOf: url)).folders[0]
        let oracle = try EncryptedSevenZipHeader(Data(contentsOf: reference)).folders[0]
        XCTAssertEqual(actual.methods, oracle.methods)
        XCTAssertEqual(actual.binds.map(\.0), oracle.binds.map(\.0))
        XCTAssertEqual(actual.binds.map(\.1), oracle.binds.map(\.1))
        XCTAssertEqual(actual.properties[0].prefix(2), oracle.properties[0].prefix(2))
        XCTAssertEqual(actual.unpackSizes.last, oracle.unpackSizes.last)
    }

    func testSevenZipEncryptedHeaderWithOnlyEmptyStreams() throws {
        for emptyArchive in [true, false] {
            let directory = try ZipTestSupport.directory("encryption-empty-header-\(emptyArchive)")
            let url = directory.appendingPathComponent("archive.7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                options: WriterOptions(password: password, encryptsSevenZipHeaders: true))
            if !emptyArchive { try writer.add(data: Data(), as: "hidden-empty-file") }
            try writer.finish()
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
            XCTAssertEqual(reader.entries.count, emptyArchive ? 0 : 1)
            if let entry = reader.entries.first { XCTAssertEqual(try reader.read(entry), Data()) }
            XCTAssertEqual(try EncryptedSevenZipHeader(Data(contentsOf: url)).packOffset, 0)
            XCTAssertThrowsError(try ArchiveReader.open(url: url))
            try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-empty")
        }
    }

    func testFortyMiBSevenZipRoundTripAndCompressionRatio() throws {
        let directory = try ZipTestSupport.directory("encryption-7z-40mib-ratio")
        let input = EncryptionTestSupport.pseudoText(mebibytes: 40)
        XCTAssertEqual(input.count, 40 * 1024 * 1024)
        let reference = try EncryptionTestSupport.wholeBufferLZMA2(input)
        // 単純なゼロ列に退化せず、圧縮可能なテキストであることも確認する。
        XCTAssertGreaterThan(reference.payload.count, input.count / 50)
        XCTAssertLessThan(reference.payload.count, input.count / 2)
        let source = directory.appendingPathComponent("corpus.txt")
        try input.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        for encrypted in [false, true] {
            let url = directory.appendingPathComponent("encrypted-\(encrypted).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                options: WriterOptions(password: encrypted ? password : nil))
            var reads = 0
            try writer.add(contentsOf: source, as: "corpus.txt") { handle, requested in
                reads += 1
                XCTAssertLessThanOrEqual(requested, 256 * 1024)
                return try handle.read(upToCount: requested) ?? Data()
            }
            XCTAssertGreaterThan(reads, 160)
            try writer.finish()
            let header = try EncryptedSevenZipHeader(Data(contentsOf: url))
            XCTAssertEqual(header.packedSizes.count, 1)
            let packedSize = try XCTUnwrap(header.packedSizes.first)
            let ratio = Double(packedSize) / Double(reference.payload.count)
            // AES の zero pad を含む packed size で、whole-buffer の ±5% に収める。
            XCTAssertLessThanOrEqual(abs(ratio - 1), 0.05, "packed=\(packedSize), whole=\(reference.payload.count)")
            try EncryptionTestSupport.verify(url, items: [.init(name: "corpus.txt", data: input)],
                password: encrypted ? password : nil) { _ in encrypted }
            try EncryptionTestSupport.run(["t"] + (encrypted ? ["-p" + password] : []) + [url.path],
                archive: url, log: "7zz-40mib-\(encrypted)")
            ZipTestSupport.report("7Z 40 MiB encrypted=\(encrypted): packed=\(packedSize), whole=\(reference.payload.count), ratio=\(ratio)")
        }
    }

    func testSevenZipUpToSixteenMiBMatchesWholeBufferDespiteShortReads() throws {
        let directory = try ZipTestSupport.directory("encryption-7z-single-chunk")
        let corpus = EncryptionTestSupport.pseudoText(mebibytes: 16)
        for mebibytes in [5, 16] {
            let input = Data(corpus.prefix(mebibytes * 1024 * 1024))
            let reference = try EncryptionTestSupport.wholeBufferLZMA2(input)
            let source = directory.appendingPathComponent("source-\(mebibytes)")
            try input.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let url = directory.appendingPathComponent("\(mebibytes).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip)
            var reads = 0
            let shortReads = [1, 65_539, 131_071]
            try writer.add(contentsOf: source, as: "corpus.txt") { handle, requested in
                defer { reads += 1 }
                XCTAssertLessThanOrEqual(requested, 256 * 1024)
                return try handle.read(upToCount: min(requested, shortReads[reads % shortReads.count])) ?? Data()
            }
            try writer.finish()
            let archive = try Data(contentsOf: url)
            let header = try EncryptedSevenZipHeader(archive)
            XCTAssertEqual(header.packedSizes, [UInt64(reference.payload.count)])
            let packedSize = try XCTUnwrap(header.packedSizes.first)
            XCTAssertEqual(archive.subdata(in: 32..<(32 + Int(packedSize))), reference.payload)
            try EncryptionTestSupport.verify(url, items: [.init(name: "corpus.txt", data: input)], password: nil) { _ in false }
        }
    }

    func testUnicodePasswordsAndFreshSaltOrIV() throws {
        let unicodePassword = "合言葉🔑e\u{301}"
        let variants: [(GyoshukuKit.ArchiveFormat, ZipEncryption)] = [(.zip, .aes256), (.zip, .zipCrypto), (.sevenZip, .aes256)]
        for (index, variant) in variants.enumerated() {
            let directory = try ZipTestSupport.directory("encryption-password-\(index)")
            var archives: [Data] = []
            for copy in 0..<2 {
                let url = directory.appendingPathComponent("\(copy).archive")
                let writer = try ArchiveWriter.create(url: url, format: variant.0,
                    options: WriterOptions(password: unicodePassword, zipEncryption: variant.1))
                try writer.add(data: Data("password bytes".utf8), as: "file", modificationDate: ZipTestSupport.date)
                try writer.finish()
                try EncryptionTestSupport.verify(url, items: [.init(name: "file", data: Data("password bytes".utf8))],
                    password: unicodePassword) { _ in true }
                try EncryptionTestSupport.run(["t", "-p" + unicodePassword, url.path], archive: url, log: "7zz-\(copy)")
                archives.append(try Data(contentsOf: url))
            }
            XCTAssertNotEqual(archives[0], archives[1])
        }
    }

    func testOptionsAreValidatedBeforeCreatingOrAccessingFiles() throws {
        let directory = try ZipTestSupport.directory("encryption-options")
        let url = directory.appendingPathComponent("missing.archive")
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ, .lha] {
            let options = WriterOptions(password: password)
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: options)) {
                XCTAssertEqual($0 as? WriterError, .unsupportedOption("password"))
            }
            XCTAssertThrowsError(try ArchiveRewriter.open(url: url, format: format, options: options)) {
                XCTAssertEqual($0 as? WriterError, .unsupportedOption("password"))
            }
        }
        for (options, expected) in [(WriterOptions(password: ""), WriterError.invalidOption("password")),
                                    (WriterOptions(encryptsSevenZipHeaders: true), .invalidOption("encryptsSevenZipHeaders"))] {
            for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: options)) {
                    XCTAssertEqual($0 as? WriterError, expected)
                }
                XCTAssertThrowsError(try ArchiveRewriter.open(url: url, format: format, options: options)) {
                    XCTAssertEqual($0 as? WriterError, expected)
                }
            }
            XCTAssertThrowsError(try ArchiveUpdater.open(url: url, options: options)) {
                XCTAssertEqual($0 as? WriterError, expected)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testZipCryptoSpoolRemovedAfterSourceChangesAndCancellation() throws {
        for failure in ["short", "grown", "mtime", "mode", "cancel"] {
            let directory = try ZipTestSupport.directory("encryption-spool-\(failure)")
            let source = directory.appendingPathComponent("source")
            try Data(repeating: 0x51, count: 600_000).write(to: source)
            let url = directory.appendingPathComponent("archive.zip")
            let writer = try ArchiveWriter.create(url: url, options: WriterOptions(password: password, zipEncryption: .zipCrypto))
            var calls = 0
            XCTAssertThrowsError(try writer.add(contentsOf: source, as: "file") { input, requested in
                calls += 1
                let spools = try EncryptionTestSupport.spoolFiles(in: directory)
                XCTAssertEqual(spools.count, 1)
                if calls == 1 {
                    let spool = try XCTUnwrap(spools.first)
                    let attributes = try FileManager.default.attributesOfItem(atPath: spool.path)
                    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                }
                if calls == 2 {
                    switch failure {
                    case "short": return Data()
                    case "grown":
                        let handle = try FileHandle(forWritingTo: source)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([1]))
                    case "mtime":
                        try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date], ofItemAtPath: source.path)
                    case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)
                    default: throw CancellationError()
                    }
                }
                return try input.read(upToCount: requested) ?? Data()
            }) {
                if failure == "cancel" { XCTAssertTrue($0 is CancellationError) }
                else { XCTAssertEqual($0 as? WriterError, .sourceChanged(failure == "short" || failure == "grown" ? "file" : source.path)) }
            }
            XCTAssertGreaterThan(calls, 1)
            XCTAssertTrue(try EncryptionTestSupport.spoolFiles(in: directory).isEmpty)
            XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
        }
    }

    func testZipCryptoSpoolCreationFailureIsWriterIOError() throws {
        let directory = try ZipTestSupport.directory("encryption-spool-io")
        let output = directory.appendingPathComponent("missing-parent/archive.zip")
        XCTAssertThrowsError(try ZipCryptoSpool(nextTo: output)) {
            guard case WriterError.io(let operation, let code) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(operation, "create ZipCrypto spool")
            XCTAssertEqual(code, ENOENT)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUpdaterEncryptsAdditionsAndPreservesOriginalRecords() throws {
        for originalEncrypted in [false, true] {
            for encryption: ZipEncryption in [.aes256, .zipCrypto] {
                let directory = try ZipTestSupport.directory("encryption-update-\(originalEncrypted)-\(encryption)")
                let url: URL
                if originalEncrypted { url = try EncryptionTestSupport.fixture(in: directory) }
                else {
                    url = directory.appendingPathComponent("source.zip")
                    let writer = try ArchiveWriter.create(url: url)
                    try writer.add(data: Data("original encrypted content\n".utf8), as: "original.txt")
                    try writer.finish()
                }
                let before = try EncryptionTestSupport.localRecords(url)
                let updater = try ArchiveUpdater.open(url: url, options: WriterOptions(password: password, zipEncryption: encryption))
                try updater.add(data: Data("added secret".utf8), as: "new.txt")
                try updater.commit()
                let after = try EncryptionTestSupport.localRecords(url)
                XCTAssertEqual(before["original.txt"], after["original.txt"])
                try EncryptionTestSupport.verify(url, items: [
                    .init(name: "original.txt", data: Data("original encrypted content\n".utf8)),
                    .init(name: "new.txt", data: Data("added secret".utf8))
                ]) { $0.name == "new.txt" || originalEncrypted }
                // 同じ clone で追加と改名・削除を混在させても既存 ciphertext は再生成しない。
                let edit = try ArchiveUpdater.open(url: url, options: WriterOptions(password: password))
                try edit.rename(entryAt: 0, to: "renamed-original.txt")
                try edit.remove(entriesAt: [1])
                try edit.add(data: Data("replacement secret".utf8), as: "replacement.txt")
                try edit.commit()
                try EncryptionTestSupport.verify(url, items: [
                    .init(name: "renamed-original.txt", data: Data("original encrypted content\n".utf8)),
                    .init(name: "replacement.txt", data: Data("replacement secret".utf8))
                ]) { $0.name == "replacement.txt" || originalEncrypted }
                let renamed = try XCTUnwrap(EncryptionTestSupport.localRecords(url)["renamed-original.txt"])
                let old = try XCTUnwrap(before["original.txt"])
                func payload(_ record: Data) -> Data {
                    let bytes = ZipBytes(data: record)
                    return Data(record.dropFirst(30 + Int(bytes.u16(26)) + Int(bytes.u16(28))))
                }
                XCTAssertEqual(payload(old), payload(renamed))
                let plain = try ArchiveUpdater.open(url: url)
                try plain.add(data: Data("plain addition".utf8), as: "plain.txt")
                try plain.commit()
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
                let entry = try XCTUnwrap(reader.entries.last)
                XCTAssertFalse(entry.isEncrypted)
                XCTAssertEqual(try reader.read(entry), Data("plain addition".utf8))
                try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-updated")
            }
        }
    }

    func testRewriterUsesSeparateInputAndOutputPasswords() throws {
        let directory = try ZipTestSupport.directory("encryption-rewriter")
        let source = try EncryptionTestSupport.fixture(in: directory)
        let original = try Data(contentsOf: source)
        let formats: [(GyoshukuKit.ArchiveFormat, ZipEncryption, Bool)] = [(.zip, .aes256, false),
            (.zip, .zipCrypto, false), (.sevenZip, .aes256, false), (.sevenZip, .aes256, true)]
        for (index, variant) in formats.enumerated() {
            let output = directory.appendingPathComponent("encrypted-\(index).archive")
            let rewriter = try ArchiveRewriter.open(url: source, password: password, output: output,
                format: variant.0, options: WriterOptions(password: password, zipEncryption: variant.1,
                                                        encryptsSevenZipHeaders: variant.2))
            try rewriter.commit()
            try EncryptionTestSupport.verify(output, items: [.init(name: "original.txt", data: Data("original encrypted content\n".utf8))]) { _ in true }
            try EncryptionTestSupport.run(["t", "-p" + password, output.path], archive: output, log: "7zz-rewrite-\(index)")
        }
        let plain = directory.appendingPathComponent("plain.zip")
        let decrypt = try ArchiveRewriter.open(url: source, password: password, output: plain, format: .zip)
        try decrypt.commit()
        try EncryptionTestSupport.verify(plain, items: [.init(name: "original.txt", data: Data("original encrypted content\n".utf8))], password: nil) { _ in false }
        let newPassword = "different-output-password"
        let encrypt = try ArchiveRewriter.open(url: plain, format: .zip, options: WriterOptions(password: newPassword))
        try encrypt.commit()
        try EncryptionTestSupport.verify(plain, items: [.init(name: "original.txt", data: Data("original encrypted content\n".utf8))], password: newPassword) { _ in true }
        let rotated = directory.appendingPathComponent("rotated.zip")
        let rotate = try ArchiveRewriter.open(url: source, password: password, output: rotated,
                                              format: .zip, options: WriterOptions(password: newPassword))
        try rotate.commit()
        try EncryptionTestSupport.verify(rotated, items: [.init(name: "original.txt", data: Data("original encrypted content\n".utf8))], password: newPassword) { _ in true }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testXattrChangesDuringDiskReadAndBeforeUpdateCommitAreAllowed() throws {
        for variant in 0..<3 {
            let directory = try ZipTestSupport.directory("encryption-xattr-\(variant)")
            let source = directory.appendingPathComponent("source")
            let data = Data(repeating: 0x5A, count: 600_007)
            try data.write(to: source)
            let url = directory.appendingPathComponent("archive")
            let writer = try ArchiveWriter.create(url: url, format: variant == 2 ? .sevenZip : .zip,
                options: WriterOptions(password: password, zipEncryption: variant == 1 ? .zipCrypto : .aes256))
            var before = stat()
            XCTAssertEqual(lstat(source.path, &before), 0)
            var calls = 0
            try writer.add(contentsOf: source, as: "file") { input, requested in
                calls += 1
                if calls == 2 { try self.setTag(source) }
                return try input.read(upToCount: requested) ?? Data()
            }
            var after = stat()
            XCTAssertEqual(lstat(source.path, &after), 0)
            XCTAssertTrue(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
            XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
            XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
            try writer.finish()
            try EncryptionTestSupport.verify(url, items: [.init(name: "file", data: data)]) { _ in true }
            if variant != 2 {
                let updater = try ArchiveUpdater.open(url: url, options: WriterOptions(password: password))
                try updater.add(data: Data([1]), as: "new")
                try setTag(url)
                try updater.commit()
                try EncryptionTestSupport.verify(url, items: [.init(name: "file", data: data), .init(name: "new", data: Data([1]))]) { _ in true }
            }
        }
    }

    private func setTag(_ url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: ["encryption-test\n6"], format: .binary, options: 0)
        let status = value.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
        }
        guard status == 0 else { throw WriterError.io(operation: "test setxattr", code: errno) }
    }

    func test300MiBStreamingEncryptionAndScratchCleanup() throws {
        let directory = try ZipTestSupport.directory("encryption-large")
        let source = directory.appendingPathComponent("300MiB.bin")
        let size: UInt64 = 300 * 1024 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: size)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: source) }
        let variants: [(GyoshukuKit.ArchiveFormat, ZipEncryption)] = [(.zip, .aes256), (.sevenZip, .aes256), (.zip, .zipCrypto)]
        for (index, variant) in variants.enumerated() {
            let scratch = directory.appendingPathComponent("output-\(index)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let url = scratch.appendingPathComponent("archive")
            let writer = try ArchiveWriter.create(url: url, format: variant.0,
                options: WriterOptions(password: password, zipEncryption: variant.1))
            var calls = 0
            try writer.add(contentsOf: source, as: "large.bin") { input, requested in
                calls += 1
                XCTAssertLessThanOrEqual(requested, 256 * 1024)
                if calls % 128 == 1 {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
                    XCTAssertEqual(contents.count, variant.1 == .zipCrypto ? 2 : 1)
                    XCTAssertEqual(try EncryptionTestSupport.spoolFiles(in: scratch).count, variant.1 == .zipCrypto ? 1 : 0)
                }
                return try input.read(upToCount: requested) ?? Data()
            }
            XCTAssertGreaterThan(calls, 1000)
            try writer.finish()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["archive"])
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertTrue(entry.isEncrypted)
            XCTAssertEqual(entry.uncompressedSize, size)
            let stream = try reader.stream(entry)
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            let zeros = buffer
            var restored: UInt64 = 0
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                XCTAssertEqual(buffer.prefix(count), zeros.prefix(count))
                restored += UInt64(count)
            }
            XCTAssertEqual(restored, size)
            try EncryptionTestSupport.run(["t", "-p" + password, url.path], archive: url, log: "7zz-large")
            if variant.1 == .zipCrypto {
                try EncryptionTestSupport.run(["-P", password, "-t", url.path], archive: url, log: "unzip-large", tool: "/usr/bin/unzip")
            }
            XCTAssertTrue(try EncryptionTestSupport.spoolFiles(in: scratch).isEmpty)
        }
    }
}
