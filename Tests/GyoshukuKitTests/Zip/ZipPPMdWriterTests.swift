import Foundation
import XCTest
import KaitoKit
@testable import GyoshukuKit

final class ZipPPMdWriterTests: XCTestCase {
    func testPresetsWithAESAndZipCrypto() throws {
        let root = try TestSupport.directory("zip-ppmd-levels")
        let items = PPMdWriterTestSupport.items()
        for preset in PPMdWriterTestSupport.presets {
            for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                let directory = try TestSupport.work(in: root), url = directory.appendingPathComponent("archive.zip")
                var options = preset.options()
                options.password = encryption == nil ? nil : "secret"
                options.zipEncryption = encryption ?? .aes256
                try PPMdWriterTestSupport.write(url, format: .zip, options: options, items: items)
                let listing = try PPMdWriterTestSupport.verify(url, items: items, password: options.password)
                for entry in SevenZipTestSupport.listingEntries(listing) where entry["Size"] != "0" {
                    let method = entry["Method"] ?? ""
                    XCTAssertTrue(method.contains("PPMd"), method)
                    XCTAssertEqual(method.contains("AES-256"), encryption == .aes256)
                }
                let bytes = ZipBytes(data: try Data(contentsOf: url))
                for record in try ZipAdditionalCompressionSupport.centralRecords(url) {
                    let cd = ZipBytes(data: record), local = Int(cd.u32(42))
                    let empty = cd.u32(24) == 0
                    XCTAssertEqual(cd.u16(6), empty ? (encryption == .aes256 ? 51 : 20) : 63)
                    XCTAssertEqual(bytes.u16(local + 4), cd.u16(6))
                    XCTAssertEqual(cd.u16(10), encryption == .aes256 ? 99 : empty ? 0 : 98)
                    XCTAssertEqual(cd.u16(8) & 2, 0)
                    if encryption == .aes256 {
                        let extra = cd.extras(0, local: false)
                        let aes = ZipBytes(data: try XCTUnwrap(extra[0x9901]))
                        XCTAssertEqual(aes.u16(5), empty ? 0 : 98)
                    } else if encryption == nil && !empty {
                        let payload = local + 30 + Int(bytes.u16(local + 26)) + Int(bytes.u16(local + 28))
                        XCTAssertEqual(bytes.u16(payload), UInt16(preset.zipOrder - 1 | (preset.memoryMiB - 1) << 4))
                    }
                }
            }
        }
    }

    func testDefaultPresetHeuristicAndSpecialEntries() throws {
        let root = try TestSupport.directory("zip-ppmd-default")
        let items = PPMdWriterTestSupport.items()
        let a = root.appendingPathComponent("default.zip"), b = root.appendingPathComponent("six.zip")
        try PPMdWriterTestSupport.write(a, format: .zip, options: .init(compressionMethod: .ppmd), items: items)
        try PPMdWriterTestSupport.write(b, format: .zip, options: .init(compressionMethod: .ppmd, ppmdLevel: 6), items: items)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        _ = try PPMdWriterTestSupport.verify(a, items: items)
        let url = root.appendingPathComponent("special.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .ppmd))
        let png = ExpectedEntry(name: "image.PNG", data: TestCorpus.random(321))
        try writer.add(data: png.data, as: png.name, modificationDate: TestSupport.date)
        try writer.addDirectory("dir/", modificationDate: TestSupport.date, ownerIDs: nil)
        let link = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: png.name)
        try writer.add(contentsOf: link, as: "link")
        try writer.add(data: Data(), as: "empty", modificationDate: TestSupport.date)
        try writer.finish()
        let special = [png, ExpectedEntry(name: "dir/", kind: .directory, permissions: 0o755),
            .init(name: "link", data: Data(png.name.utf8), kind: .symlink, permissions: 0o755, date: nil), .init(name: "empty")]
        _ = try PPMdWriterTestSupport.verify(url, items: special)
        for record in try ZipAdditionalCompressionSupport.centralRecords(url) { XCTAssertEqual(ZipBytes(data: record).u16(10), 0) }
    }

    func testUpdaterAndRewriterSelectPPMd() throws {
        let root = try TestSupport.directory("zip-ppmd-edit")
        let old = ExpectedEntry(name: "old.txt", data: Data("existing".utf8))
        let added = ExpectedEntry(name: "added", data: LZMAEncoderCorpus.text(size: 8193))
        for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
            let work = try TestSupport.work(in: root), source = work.appendingPathComponent("source.zip")
            try PPMdWriterTestSupport.write(source, format: .zip, options: .init(), items: [old])
            let options = WriterOptions(compressionMethod: .ppmd, ppmdOrder: 7, ppmdMemoryMiB: 3,
                password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256)
            let updater = try ArchiveUpdater.open(url: source, options: options)
            let disk = work.appendingPathComponent("input")
            try added.data.write(to: disk)
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: disk.path)
            try updater.add([.init(path: added.name, source: .contents(of: disk))], events: nil)
            try updater.commit()
            let listing = try PPMdWriterTestSupport.verify(source, items: [old, added], password: options.password)
            XCTAssertTrue(listing.contains("PPMd"), listing)
            let output = work.appendingPathComponent("rewritten.zip")
            let rewriter = try ArchiveRewriter.open(url: source, password: options.password, output: output, format: .zip, options: options)
            try rewriter.commit()
            _ = try PPMdWriterTestSupport.verify(output, items: [old, added], password: options.password)
            for record in try ZipAdditionalCompressionSupport.centralRecords(output) {
                XCTAssertEqual(ZipBytes(data: record).u16(10), encryption == .aes256 ? 99 : 98)
            }
        }
    }

    func testTwentyMiBTextWithRestartsAndThreadIndependentStream() throws { try verifyRestarts(large: false) }

    func testTwentyMiBTextWithRestartsAndThreadIndependentStreamFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyRestarts(large: true)
    }

    private func verifyRestarts(large: Bool) throws {
        let root = try TestSupport.directory("zip-ppmd-restarts")
        let item = ExpectedEntry(name: "large.txt", data: large ? EncoderTestCorpus.sourceTwentyMiB : EncoderTestCorpus.restoration)
        // 複数の IO read / write の後でも一つの model と stream を保つ。
        XCTAssertGreaterThan(item.data.count, IOChunk.size)
        var baseline: Data?
        for threads in [1, 4] {
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.zip")
            let options = WriterOptions(compressionMethod: .ppmd, ppmdOrder: 6, ppmdMemoryMiB: 1, compressionThreads: threads)
            XCTAssertEqual(options.maximumPendingInputBytes(for: .zip), threads == 1 ? 0 : 64 << 20)
            try PPMdWriterTestSupport.write(url, format: .zip, options: options, items: [item])
            let bytes = try Data(contentsOf: url)
            if let baseline {
                // 全 bytes が同じなら、先に行った t / l / x・KaitoKit の検証も同じ結果になる。
                XCTAssertEqual(bytes, baseline)
            } else {
                baseline = bytes
                _ = try PPMdWriterTestSupport.verify(url, items: [item])
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testReverseSevenZipToolArchiveAndZIP64Reservation() throws {
        let work = try TestSupport.directory("zip-ppmd-reverse-zip64")
        let item = ExpectedEntry(name: "text.txt", data: LZMAEncoderCorpus.text(size: 65_537))
        try item.data.write(to: work.appendingPathComponent(item.name))
        let reverse = work.appendingPathComponent("reference.zip")
        try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-tzip", "-mm=PPMd", reverse.path, item.name],
            in: work, log: "7zz-a", workingDirectory: work)
        _ = try PPMdWriterTestSupport.verify(reverse, items: [item], metadata: false)
        XCTAssertEqual(ZipBytes(data: try XCTUnwrap(ZipAdditionalCompressionSupport.centralRecords(reverse).first)).u16(10), 98)
        let url = work.appendingPathComponent("unused")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
            let writer = ZipWriter(output: handle, url: url,
                options: .init(compressionMethod: .ppmd, password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256),
                deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
            let entry = try writer.makeEntry(name: "large", mode: 0o100644, size: UInt64(UInt32.max) - 1,
                date: TestSupport.date, atime: nil, owners: nil)
            XCTAssertEqual(entry.reservedZIP64, encryption != .zipCrypto)
            var final = entry
            final.compressedSize = UInt64(UInt32.max) + 1
            if encryption != .zipCrypto { XCTAssertEqual(final.local().count, entry.local().count) }
            let local = ZipBytes(data: final.local()), central = ZipBytes(data: final.central())
            XCTAssertEqual(local.u16(4), 63); XCTAssertEqual(central.u16(6), 63)
            XCTAssertEqual(local.u32(18), UInt32.max); XCTAssertEqual(local.u32(22), UInt32.max)
            XCTAssertEqual(central.u32(20), UInt32.max); XCTAssertEqual(central.u32(24), UInt32(UInt32.max - 1))
        }
    }
}
