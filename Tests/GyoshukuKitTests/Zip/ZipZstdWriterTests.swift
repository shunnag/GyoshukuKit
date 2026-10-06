import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipZstdWriterTests: XCTestCase {
    private func verify(_ url: URL, items: [ExpectedEntry], password: String? = nil) throws {
        let directory = url.deletingLastPathComponent()
        let passwordArgs = password.map { ["-p\($0)"] } ?? []
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items, password: password)
        let tested = try TestSupport.run(ReferenceTool.sevenZip, ["t", url.path] + passwordArgs, in: directory, log: "7zz-t")
        XCTAssertTrue(tested.contains("Everything is Ok"), tested)
        let listing = try TestSupport.run(ReferenceTool.sevenZip, ["l", "-slt", url.path] + passwordArgs, in: directory, log: "7zz-l")
        XCTAssertTrue(listing.lowercased().contains("zstd"), listing)
        let extracted = directory.appendingPathComponent("extracted")
        try TestSupport.run(ReferenceTool.sevenZip, ["x", "-y", "-o\(extracted.path)", url.path] + passwordArgs,
                            in: directory, log: "7zz-x")
        for item in items { XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(item.name)), item.data, item.name) }
    }

    func testLevelsAESAndZipCryptoWithSevenZipAndRawFrameOracle() throws {
        let root = try TestSupport.directory("zip-zstd-levels-encryption")
        let info = try ReferenceTool.run(ReferenceTool.sevenZip, ["i"], in: root, log: "7zz-i")
        XCTAssertTrue(info.utf8Text.contains("zstd"))
        let items = [ExpectedEntry(name: "empty"), .init(name: "one", data: Data([0xA7])),
                     .init(name: "日本語.txt", data: TestCorpus.pseudoSource(mebibytes: 1)),
                     .init(name: "random.bin", data: TestCorpus.random(256 << 10))]
        for level in [1, 3, 19] {
            for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
                let directory = try TestSupport.work(in: root)
                let url = directory.appendingPathComponent("archive.zip")
                let options = WriterOptions(compressionMethod: .zstd, zstdLevel: level, useCompressionHeuristic: false,
                    password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256, compressionThreads: 4)
                let writer = try ArchiveWriter.create(url: url, options: options)
                for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                try writer.finish()
                XCTAssertEqual(options.maximumPendingInputBytes(for: .zip), 0)
                try verify(url, items: items, password: options.password)
                let bytes = ZipBytes(data: try Data(contentsOf: url))
                for (index, record) in try ZipAdditionalCompressionSupport.centralRecords(url).enumerated() {
                    let cd = ZipBytes(data: record), local = Int(cd.u32(42)), empty = items[index].data.isEmpty
                    XCTAssertEqual(cd.u16(6), empty ? (encryption == .aes256 ? 51 : 20) : 63)
                    XCTAssertEqual(bytes.u16(local + 4), cd.u16(6))
                    XCTAssertEqual(cd.u16(8) & 2, 0)
                    XCTAssertEqual(cd.u16(10), encryption == .aes256 ? 99 : empty ? 0 : 93)
                    if encryption == .aes256 {
                        let aes = ZipBytes(data: try XCTUnwrap(cd.extras(0, local: false)[0x9901]))
                        XCTAssertEqual(aes.u16(5), empty ? 0 : 93)
                    } else if encryption == nil && !empty {
                        let start = local + 30 + Int(bytes.u16(local + 26)) + Int(bytes.u16(local + 28))
                        let frame = bytes.data.subdata(in: start..<(start + Int(cd.u32(20))))
                        XCTAssertEqual(try ZstdWriterTestSupport.frames(frame).count, 1)
                        let stream = directory.appendingPathComponent("entry-\(index).zst")
                        try frame.write(to: stream)
                        try SingleStreamTestSupport.assertCLI(stream, format: .zstd, input: items[index].data,
                                                            in: directory, label: "entry-\(index)")
                    }
                }
            }
        }
    }

    func testLargeEntryStaysOneFrameAndThreadIndependent() throws {
        let root = try TestSupport.directory("zip-zstd-single-frame")
        let item = ExpectedEntry(name: "large.txt", data: Data(repeating: 0x41, count: (9 << 20) + 129))
        var baseline: Data?
        for threads in [1, 4] {
            let directory = try TestSupport.work(in: root), url = directory.appendingPathComponent("archive.zip")
            let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .zstd, compressionThreads: threads))
            try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
            try writer.finish()
            let bytes = ZipBytes(data: try Data(contentsOf: url))
            if let baseline { XCTAssertEqual(bytes.data, baseline) } else { baseline = bytes.data }
            let start = 30 + Int(bytes.u16(26)) + Int(bytes.u16(28))
            let frame = bytes.data.subdata(in: start..<(start + Int(bytes.u32(18))))
            XCTAssertEqual(try ZstdWriterTestSupport.frames(frame).map(\.contentSize), [UInt64(item.data.count)])
            try verify(url, items: [item])
        }
    }

    func testUpdaterBatchAdditionsAndRewriterWithEncryption() throws {
        let root = try TestSupport.directory("zip-zstd-edit")
        let old = ExpectedEntry(name: "old", data: Data("existing".utf8))
        let added = ExpectedEntry(name: "added", data: Data("Zstandard addition\n".utf8))
        for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
            let directory = try TestSupport.work(in: root), source = directory.appendingPathComponent("source.zip")
            let writer = try ArchiveWriter.create(url: source)
            try writer.add(data: old.data, as: old.name, modificationDate: TestSupport.date)
            try writer.finish()
            let options = WriterOptions(compressionMethod: .zstd, password: encryption == nil ? nil : "secret",
                                        zipEncryption: encryption ?? .aes256)
            let disk = directory.appendingPathComponent("input")
            try added.data.write(to: disk)
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: disk.path)
            let updater = try ArchiveUpdater.open(url: source, options: options)
            try updater.add([.init(path: added.name, source: .contents(of: disk))], events: nil)
            try updater.commit()
            try verify(source, items: [old, added], password: options.password)
            let outputDirectory = try TestSupport.work(in: directory), output = outputDirectory.appendingPathComponent("rewritten.zip")
            let rewriter = try ArchiveRewriter.open(url: source, password: options.password, output: output, format: .zip, options: options)
            try rewriter.remove(entriesAt: [0])
            try rewriter.rename(entryAt: 1, to: "renamed")
            try rewriter.add(data: Data([3]), as: "new", modificationDate: TestSupport.date)
            try rewriter.commit()
            try verify(output, items: [.init(name: "renamed", data: added.data), .init(name: "new", data: Data([3]))], password: options.password)
            for record in try ZipAdditionalCompressionSupport.centralRecords(output) {
                let cd = ZipBytes(data: record)
                XCTAssertEqual(cd.u16(6), 63)
                XCTAssertEqual(cd.u16(10), encryption == .aes256 ? 99 : 93)
            }
        }
    }

    func testZIP64ReservationIncludesFrameOverheadAndVersion() throws {
        let directory = try TestSupport.directory("zip-zstd-zip64"), url = directory.appendingPathComponent("unused")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for encryption: ZipEncryption? in [nil, .aes256, .zipCrypto] {
            let writer = ZipWriter(output: handle, url: url,
                options: .init(compressionMethod: .zstd, password: encryption == nil ? nil : "secret", zipEncryption: encryption ?? .aes256),
                deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
            let entry = try writer.makeEntry(name: "large", mode: FileMode.regular | 0o644, size: UInt64(UInt32.max) - 1,
                                            date: TestSupport.date, atime: nil, owners: nil)
            XCTAssertEqual(entry.reservedZIP64, encryption != .zipCrypto)
            var final = entry
            final.compressedSize = UInt64(UInt32.max) + 1
            if encryption != .zipCrypto { XCTAssertEqual(entry.local().count, final.local().count) }
            let local = ZipBytes(data: final.local()), central = ZipBytes(data: final.central())
            XCTAssertEqual(local.u16(4), 63); XCTAssertEqual(central.u16(6), 63)
            XCTAssertEqual(local.u32(18), UInt32.max); XCTAssertEqual(local.u32(22), UInt32.max)
            XCTAssertEqual(central.u32(20), UInt32.max)
        }
    }
}
