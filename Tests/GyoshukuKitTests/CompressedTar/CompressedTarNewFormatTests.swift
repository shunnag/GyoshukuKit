import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class CompressedTarNewFormatTests: XCTestCase {
    /// 乱数と text の双方を含み、16 MiB の member 上限を越える。
    private func mixed() -> Data {
        var data = Data()
        let random = TestCorpus.random(65_536)
        let text = Data(repeating: 0x61, count: 65_536)
        for _ in 0..<160 { data.append(random); data.append(text) }
        return data
    }

    private func verifyTree(_ format: GyoshukuKit.ArchiveFormat, level: Int?, label: String) throws {
        let directory = try TestSupport.directory(label)
        let tree = directory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty-directory"), withIntermediateDirectories: true)
        let payloads = ["file": Data("file contents\n".utf8), "empty": Data(),
                        "日本語.txt": Data("資料\n".utf8), "large": mixed()]
        for (name, bytes) in payloads { try bytes.write(to: tree.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "日本語.txt")
        let url = directory.appendingPathComponent("archive." + format.testFileExtension)
        let plain = directory.appendingPathComponent("plain.tar")
        let options = WriterOptions(lzmaLevel: level, compressionThreads: 2)
        for (output, kind) in [(plain, GyoshukuKit.ArchiveFormat.tar), (url, format)] {
            let writer = try ArchiveWriter.create(url: output, format: kind, options: options)
            try writer.add(contentsOf: tree, as: "tree")
            XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: kind))
            let pending = writer.pendingInputBytes
            var emitted: UInt64 = 0
            try writer.finishAdditions { update in
                XCTAssertEqual(update.totalBytes, pending)
                emitted = update.completedBytes
            }
            XCTAssertEqual(writer.pendingInputBytes, 0)
            XCTAssertEqual(emitted, pending)
            try writer.finish()
        }
        let streamFormat = try SingleStreamTestSupport.format(format)
        try SingleStreamTestSupport.assertCLI(url, format: streamFormat, input: Data(contentsOf: plain),
                                             in: directory, label: "stream")
        let listing = try SingleStreamTestSupport.tarTool(url, format: streamFormat, arguments: ["-tvf", "-"],
                                                        in: directory, label: "listing")
        XCTAssertTrue(listing.contains("日本語.txt"), listing)
        XCTAssertEqual(listing.split(separator: "\n").count, 7)
        let extracted = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try SingleStreamTestSupport.tarTool(url, format: streamFormat, arguments: ["-xf", "-", "-C", extracted.path],
                                              in: directory, label: "extract")
        for (name, bytes) in payloads {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("tree/" + name)), bytes, name)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("tree/link").path), "日本語.txt")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: extracted.appendingPathComponent("tree/empty-directory").path)[.type] as? FileAttributeType, .typeDirectory)
        let expected = try ArchiveReader.open(url: plain)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), expected.entries.map(\.name))
        for (entry, previous) in zip(reader.entries, expected.entries) {
            XCTAssertEqual(entry.kind, previous.kind)
            if entry.kind == .symlink { XCTAssertEqual(entry.formatSpecific["linkPath"], "日本語.txt") }
            else { XCTAssertEqual(try reader.read(entry), try expected.read(previous), entry.name) }
        }
        if format == .tarLzip {
            let bytes = try Data(contentsOf: url)
            let members = try SingleStreamTestSupport.lzipMemberRanges(bytes)
            XCTAssertGreaterThan(members.count, 1)
            if level == 0 { XCTAssertGreaterThanOrEqual(members.count, 4) }
        }
        try FileManager.default.removeItem(at: tree)
        try FileManager.default.removeItem(at: extracted)
        try FileManager.default.removeItem(at: plain)
    }

    func testTarLZMA() throws { try verifyTree(.tarLZMA, level: nil, label: "tar-lzma-tree") }
    func testTarLzipLevelsAndMultipleMembers() throws {
        for level in [0, 6, 9] { try verifyTree(.tarLzip, level: level, label: "tar-lzip-tree-\(level)") }
    }
    func testTarLZ4() throws { try verifyTree(.tarLZ4, level: nil, label: "tar-lz4-tree") }
    func testTarBrotli() throws { try verifyTree(.tarBrotli, level: nil, label: "tar-brotli-tree") }
    func testTarCompress() throws { try verifyTree(.tarCompress, level: nil, label: "tar-compress-tree") }

    func testSpliceRoutesRequireRewriteWithoutCreatingFiles() throws {
        for format in SingleStreamTestSupport.newTarFormats {
            let directory = try TestSupport.directory("compressed-tar-new-route-\(format)")
            let source = directory.appendingPathComponent("source." + format.testFileExtension)
            let writer = try ArchiveWriter.create(url: source, format: format)
            try writer.add(data: Data([1, 2, 3]), as: "file", modificationDate: TestSupport.date)
            try writer.finish()
            let reader = try ArchiveReader.open(url: source, options: CompressedTarTestSupport.readerOptions)
            XCTAssertNil(CompressedTarUpdater.assess(reader: reader))
            let output = directory.appendingPathComponent("output." + format.testFileExtension)
            do {
                _ = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
                XCTFail("splice accepted unsupported container")
            } catch UpdaterRouteError.requiresRewrite(let reason) {
                XCTAssertTrue(reason.contains("ArchiveRewriter"))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        }
    }

    func testNewFormatEmptyArchivesAndInvalidOptions() throws {
        let directory = try TestSupport.directory("compressed-tar-new-empty")
        for format in SingleStreamTestSupport.newTarFormats {
            let output = directory.appendingPathComponent("empty." + format.testFileExtension)
            let writer = try ArchiveWriter.create(url: output, format: format)
            try writer.finish()
            XCTAssertTrue(try ArchiveReader.open(url: output).entries.isEmpty)
            let invalid = directory.appendingPathComponent("invalid-\(format)")
            XCTAssertThrowsError(try ArchiveWriter.create(url: invalid, format: format, options: WriterOptions(lzmaLevel: 10)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
        }
    }
}
