import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class CompressedTarZstdTests: XCTestCase {
    private func verify(_ url: URL, items: [ExpectedEntry], directory: URL, label: String) throws {
        try SingleStreamTestSupport.check(url, format: .zstd, in: directory, label: label)
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items)
        let extracted = directory.appendingPathComponent(label + "-extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try SingleStreamTestSupport.tarTool(url, format: .zstd,
            arguments: ["-xf", "-", "-C", extracted.path], in: directory, label: label + "-tar")
        for item in items { XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(item.name)), item.data, item.name) }
    }

    func testLevelsOneThreeAndNineteenWithRealTools() throws {
        for level in [1, 3, 19] {
            let directory = try TestSupport.directory("tar-zstd-level-\(level)")
            let url = directory.appendingPathComponent("archive.tar.zst")
            let items = [ExpectedEntry(name: "text.txt", data: TestCorpus.pseudoSource(mebibytes: 1)),
                         .init(name: "日本語.txt", data: Data("内容\n".utf8)), .init(name: "empty")]
            let writer = try ArchiveWriter.create(url: url, format: .tarZstd,
                options: .init(zstdLevel: level, compressionThreads: 4))
            for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
            try writer.finish()
            try verify(url, items: items, directory: directory, label: "level-\(level)")
            let frames = try ZstdWriterTestSupport.frames(Data(contentsOf: url))
            XCTAssertEqual(frames.count, 2) // member 群と独立した tar 終端。
        }
    }

    func testTwentyMiBAndMemberBoundariesWithFourThreads() throws {
        let directory = try TestSupport.directory("tar-zstd-twenty-mib")
        var body = Data(repeating: 0x41, count: 20 << 20)
        body.replaceSubrange(0..<65_536, with: TestCorpus.random(65_536))
        let items = [ExpectedEntry(name: "before", data: Data([1])), .init(name: "large", data: body),
                     .init(name: "after", data: Data([2]))]
        var baseline: Data?
        for threads in [1, 4] {
            let url = directory.appendingPathComponent("threads-\(threads).tar.zst")
            let options = WriterOptions(compressionThreads: threads)
            let writer = try ArchiveWriter.create(url: url, format: .tarZstd, options: options)
            for item in items {
                try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .tarZstd))
            }
            let pending = writer.pendingInputBytes
            try writer.finishAdditions { XCTAssertEqual($0.totalBytes, pending) }
            XCTAssertEqual(writer.pendingInputBytes, 0)
            try writer.finish()
            let bytes = try Data(contentsOf: url)
            if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
            let frames = try ZstdWriterTestSupport.frames(bytes)
            XCTAssertEqual(frames.map(\.contentSize), [1024, 512] + Array(repeating: UInt64(4 << 20), count: 5) + [1024, 7680])
            try verify(url, items: items, directory: directory, label: "threads-\(threads)")
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: directory) }
    }

    func testRewriterAddDeleteRenameAndUpdaterRefusal() throws {
        let directory = try TestSupport.directory("tar-zstd-edit")
        let url = directory.appendingPathComponent("archive.tar.zst")
        let writer = try ArchiveWriter.create(url: url, format: .tarZstd)
        try writer.add(data: Data([1]), as: "remove", modificationDate: TestSupport.date)
        try writer.add(data: Data([2]), as: "rename", modificationDate: TestSupport.date)
        try writer.finish()
        let reader = try ArchiveReader.open(url: url, options: CompressedTarTestSupport.readerOptions)
        XCTAssertNil(reader.tarEditingSnapshot()?.chunkMap)
        XCTAssertNil(CompressedTarUpdater.assess(reader: reader))
        let refused = directory.appendingPathComponent("refused.tar.zst")
        XCTAssertThrowsError(try CompressedTarUpdater.open(
            reader: ArchiveReader.open(url: url, options: CompressedTarTestSupport.readerOptions), output: refused, format: .tarZstd)) {
            XCTAssertTrue(String(describing: $0).contains("ArchiveRewriter"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
        let editor = try ArchiveRewriter.open(url: url, format: .tarZstd)
        try editor.remove(entriesAt: [0])
        try editor.rename(entryAt: 1, to: "renamed")
        try editor.add(data: Data([3]), as: "added", modificationDate: TestSupport.date)
        try editor.commit()
        try verify(url, items: [.init(name: "renamed", data: Data([2])), .init(name: "added", data: Data([3]))],
                   directory: directory, label: "edited")
    }
}
