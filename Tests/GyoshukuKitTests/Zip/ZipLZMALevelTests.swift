import Foundation
import XCTest
import KaitoKit
@testable import GyoshukuKit

final class ZipLZMALevelTests: XCTestCase {
    func testLZMAAndXZPresetsWithAESAndZipCrypto() throws {
        let root = try TestSupport.directory("zip-lzma-levels")
        let items = LZMAWriterTestSupport.items()
        for method in [CompressionMethod.lzma, .xz] {
            for preset in LZMAWriterTestSupport.presets {
                for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                    let directory = try TestSupport.work(in: root), url = directory.appendingPathComponent("archive.zip")
                    let options = WriterOptions(compressionMethod: method, lzmaLevel: preset.level, lzmaExtreme: preset.extreme,
                        useCompressionHeuristic: false, password: encryption == nil ? nil : "secret",
                        zipEncryption: encryption ?? .aes256, compressionThreads: 4)
                    try LZMAWriterTestSupport.write(url, format: .zip, options: options, items: items)
                    let listing = try LZMAWriterTestSupport.verify(url, items: items, password: options.password)
                    // 7-Zip 26.03 の ZIP listing は辞書を省略し、LZMA:eos / AES-256 LZMA:eos と表示する。
                    XCTAssertTrue(listing.split(separator: "\n").filter { $0.hasPrefix("Method = ") }
                        .contains { $0.lowercased().contains(method == .lzma ? "lzma:eos" : "xz") }, listing)
                    if method == .lzma { XCTAssertTrue(listing.contains(":eos"), listing) }
                    let bytes = ZipBytes(data: try Data(contentsOf: url))
                    let record = ZipBytes(data: try XCTUnwrap(ZipAdditionalCompressionSupport.centralRecords(url).first))
                    XCTAssertEqual(bytes.u16(6) & 2, method == .lzma ? 2 : 0)
                    XCTAssertEqual(record.u16(8), bytes.u16(6))
                    XCTAssertEqual(bytes.u16(4), method == .lzma ? 63 : encryption == .aes256 ? 51 : 20)
                    XCTAssertEqual(record.u16(6), bytes.u16(4))
                    if encryption == nil {
                        let payload = try LZMAWriterTestSupport.zipPayload(url)
                        if method == .lzma {
                            XCTAssertEqual(payload.prefix(5), Data([26, 3, 5, 0, 0x5D]))
                            let dict = (0..<4).reduce(0) { $0 | Int(payload[5 + $1]) << ($1 * 8) }
                            XCTAssertEqual(dict, preset.dictionary)
                        } else {
                            try LZMAWriterTestSupport.assertXZProperty(payload, property: preset.property)
                            let stream = directory.appendingPathComponent("payload.xz")
                            try payload.write(to: stream)
                            try TestSupport.run(ReferenceTool.xz, ["-t", stream.path], in: directory, log: "xz-t")
                        }
                    }
                }
            }
        }
    }

    func testLZMANilLevelMeansSixAndReverseSevenZipArchive() throws {
        let directory = try TestSupport.directory("zip-lzma-nil-reverse")
        let items = [ExpectedEntry(name: "text.txt", data: LZMAEncoderCorpus.text(size: 65537))]
        let a = directory.appendingPathComponent("nil.zip"), b = directory.appendingPathComponent("six.zip")
        try LZMAWriterTestSupport.write(a, format: .zip, options: .init(compressionMethod: .lzma, lzmaExtreme: true), items: items)
        try LZMAWriterTestSupport.write(b, format: .zip, options: .init(compressionMethod: .lzma, lzmaLevel: 6), items: items)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        _ = try LZMAWriterTestSupport.verify(a, items: items)
        try items[0].data.write(to: directory.appendingPathComponent(items[0].name))
        let reverse = directory.appendingPathComponent("7zz.zip")
        try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-tzip", "-mm=LZMA", reverse.path, items[0].name],
            in: directory, log: "7zz-a", workingDirectory: directory)
        let record = ZipBytes(data: try XCTUnwrap(ZipAdditionalCompressionSupport.centralRecords(reverse).first))
        XCTAssertEqual(record.u16(10), 14)
        try TestSupport.assertKaitoKitRoundTrip(reverse, expected: items.map { .init(name: $0.name, data: $0.data, date: nil) }, comparesMetadata: false)
    }

    func testUpdaterAddsAndRewriterUsesLZMAAndXZLevels() throws {
        let root = try TestSupport.directory("zip-lzma-edit")
        let items = [ExpectedEntry(name: "old.txt", data: Data("existing".utf8))]
        for method in [CompressionMethod.lzma, .xz] {
            for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                let directory = try TestSupport.work(in: root), source = directory.appendingPathComponent("source.zip")
                try LZMAWriterTestSupport.write(source, format: .zip, options: .init(), items: items)
                let options = WriterOptions(compressionMethod: method, lzmaLevel: 0, useCompressionHeuristic: false,
                    password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256, compressionThreads: 4)
                let added = ExpectedEntry(name: "added", data: LZMAEncoderCorpus.text(size: 8193))
                let updater = try ArchiveUpdater.open(url: source, options: options)
                let disk = directory.appendingPathComponent("disk-input")
                try added.data.write(to: disk)
                try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: disk.path)
                try updater.add([.init(path: added.name, source: .contents(of: disk))], events: nil)
                try updater.commit()
                _ = try LZMAWriterTestSupport.verify(source, items: items + [added], password: options.password)
                let output = directory.appendingPathComponent("rewritten.zip")
                let rewriter = try ArchiveRewriter.open(url: source, password: options.password, output: output, format: .zip, options: options)
                try rewriter.commit()
                _ = try LZMAWriterTestSupport.verify(output, items: items + [added], password: options.password)
                for record in try ZipAdditionalCompressionSupport.centralRecords(output) {
                    let cd = ZipBytes(data: record)
                    XCTAssertEqual(cd.u16(10), encryption == .aes256 ? 99 : method.rawValue)
                }
            }
        }
    }

    func testLZMAZIP64ReservationAndEOSFlags() throws {
        let directory = try TestSupport.directory("zip-lzma-zip64")
        let url = directory.appendingPathComponent("unused")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let writer = ZipWriter(output: handle, url: url, options: .init(compressionMethod: .lzma),
            deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
        let entry = try writer.makeEntry(name: "large", mode: FileMode.regular | 0o644, size: UInt64(UInt32.max) - 1,
            date: TestSupport.date, atime: nil, owners: nil)
        XCTAssertTrue(entry.reservedZIP64)
        var final = entry
        final.compressedSize = UInt64(UInt32.max) + 1
        XCTAssertEqual(final.local().count, entry.local().count)
        XCTAssertEqual(ZipBytes(data: final.local()).u16(4), 63)
        XCTAssertEqual(ZipBytes(data: final.local()).u16(6) & 2, 2)
    }

    func testOwnXZMultiplePiecesFormOneStreamAndIgnoreThreadCount() throws {
        let root = try TestSupport.directory("zip-lzma-xz-pieces")
        let item = ExpectedEntry(name: "large", data: Data(repeating: 0x5A, count: 17 << 20))
        var previous: Data?
        for threads in [1, 4] {
            let directory = try TestSupport.work(in: root), url = directory.appendingPathComponent("archive.zip")
            try LZMAWriterTestSupport.write(url, format: .zip,
                options: .init(compressionMethod: .xz, lzmaLevel: 1, compressionThreads: threads), items: [item])
            let bytes = try Data(contentsOf: url)
            if let previous { XCTAssertEqual(bytes, previous) }
            previous = bytes
            let payload = try LZMAWriterTestSupport.zipPayload(url)
            try LZMAWriterTestSupport.assertXZProperty(payload, property: 16)
            let stream = directory.appendingPathComponent("payload.xz")
            try payload.write(to: stream)
            let listing = try TestSupport.run(ReferenceTool.xz, ["-l", "--robot", stream.path], in: directory, log: "xz-l")
            XCTAssertTrue(listing.contains("file\t1\t2\t"), listing)
            _ = try LZMAWriterTestSupport.verify(url, items: [item])
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }
}
