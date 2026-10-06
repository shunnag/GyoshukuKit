import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipSolidWriterTests: XCTestCase {
    private var items: [ExpectedEntry] {
        [.init(name: "one", data: Data(repeating: 0x41, count: 6000)),
         .init(name: "empty"), .init(name: "dir/", kind: .directory, permissions: 0o755),
         .init(name: "two", data: TestCorpus.random(4000)),
         .init(name: "three", data: Data(repeating: 0x42, count: 3000)), .init(name: "empty-tail")]
    }

    func testEveryMethodAppleOwnLZMA2AndEncryption() throws {
        let root = try TestSupport.directory("7z-solid-methods")
        let methods: [(SevenZipCompressionMethod, Int?)] = [(.lzma2, nil), (.lzma2, 1), (.lzma, 1), (.deflate, nil), (.bzip2, nil), (.copy, nil)]
        for (method, level) in methods {
            for mode in 0..<3 {
                let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
                let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(), lzmaLevel: level,
                    password: mode == 0 ? nil : "secret", encryptsSevenZipHeaders: mode == 2, compressionThreads: 2)
                try SevenZipMethodTestSupport.write(url, items: items, options: options)
                let model = try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true)
                XCTAssertEqual(model.folders[0].substreamIndices.count, 3)
                XCTAssertEqual(model.folders[0].isEncrypted, mode != 0)
                XCTAssertEqual(model.header.encrypted, mode == 2)
            }
        }
    }

    func testBlockSizeFileCountAndOff() throws {
        let root = try TestSupport.directory("7z-solid-limits")
        let cases: [(SevenZipSolidMode, Int, Bool)] = [(.off, 3, false), (.on(blockSize: 1), 3, false),
            (.on(blockSize: 7000), 2, true), (.on(blockSize: 13_000), 1, true),
            (.on(blockSize: .max, filesPerBlock: 2), 2, true), (.on(filesPerBlock: 1), 3, false)]
        for (mode, blocks, solid) in cases {
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
            let options = WriterOptions(sevenZipMethod: .copy, sevenZipSolid: mode)
            try SevenZipMethodTestSupport.write(url, items: items, options: options)
            try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: blocks, solid: solid)
        }
    }

    func testTenThousandSmallFiles() throws {
        let root = try TestSupport.directory("7z-solid-10000"), url = root.appendingPathComponent("archive.7z")
        let options = WriterOptions(sevenZipSolid: .on(), compressionThreads: 2)
        let items = (0..<10_000).map { i in ExpectedEntry(name: String(format: "file-%05d", i), data: Data("small file \(i)\n".utf8)) }
        try SevenZipMethodTestSupport.write(url, items: items, options: options)
        try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true)
    }

    func testShortReadsDrainAndBoundedInput() throws {
        let root = try TestSupport.directory("7z-solid-short-reads")
        let options = WriterOptions(sevenZipMethod: .deflate, sevenZipSolid: .on(blockSize: 13_000), sevenZipFilter: .bcjX86)
        var baseline: Data?
        for drain in [false, true] {
            let url = root.appendingPathComponent("\(drain).7z")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writer = try SevenZipWriter(output: FileHandle(forWritingTo: url), url: url, options: options, chunkSize: 31)
            for item in items {
                var offset = 0
                try writer.add(name: item.name, mode: item.kind == .directory ? 0o40755 : 0o100644,
                    size: UInt64(item.data.count), date: TestSupport.date) { count in
                    let end = min(item.data.count, offset + min(count, 3))
                    defer { offset = end }
                    return item.data.subdata(in: offset..<end)
                }
            }
            XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .sevenZip))
            if drain {
                var emitted: UInt64 = 0
                let pending = writer.pendingInputBytes
                try writer.finishAdditions { emitted += $0 }
                XCTAssertEqual(emitted, pending); XCTAssertEqual(writer.pendingInputBytes, 0)
            }
            try writer.finish()
            let data = try Data(contentsOf: url)
            if let baseline { XCTAssertEqual(data, baseline) } else { baseline = data }
            try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true, filter: "BCJ")
        }
    }

    func testInvalidOptionsAreRejectedBeforeCreation() throws {
        let root = try TestSupport.directory("7z-solid-invalid")
        for options in [WriterOptions(sevenZipSolid: .on(blockSize: 0)), WriterOptions(sevenZipSolid: .on(filesPerBlock: 0)),
                        WriterOptions(sevenZipFilter: .delta(distance: 0)), WriterOptions(sevenZipFilter: .delta(distance: 257))] {
            let url = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .sevenZip, options: options))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(WriterOptions().resolvedSevenZipBlockSize, 64 << 20)
        XCTAssertEqual(WriterOptions(lzmaLevel: 9).resolvedSevenZipBlockSize, 128 << 20)
    }

    func testLargeFileStreamsAcrossLZMA2ResetsAndExceedsBlockLimit() throws {
        let root = try TestSupport.directory("7z-solid-large-stream")
        let block = SevenZipSolidFilterSupport.macho(arm64: false, size: 65_536)
        var payload = Data()
        for _ in 0..<257 { payload.append(block) }
        let items: [ExpectedEntry] = [.init(name: "large", data: payload), .init(name: "tail", data: block)]
        let url = root.appendingPathComponent("archive.7z")
        let options = WriterOptions(sevenZipSolid: .on(blockSize: 1 << 20), sevenZipFilter: .bcjX86, compressionThreads: 2)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try SevenZipWriter(output: FileHandle(forWritingTo: url), url: url, options: options)
        var largestRequest = 0
        for item in items {
            var offset = 0
            try writer.add(name: item.name, mode: 0o100644, size: UInt64(item.data.count), date: TestSupport.date) { count in
                largestRequest = max(largestRequest, count)
                let end = min(item.data.count, offset + count)
                defer { offset = end }
                return item.data.subdata(in: offset..<end)
            }
            XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .sevenZip))
        }
        XCTAssertLessThanOrEqual(largestRequest, 256 << 10)
        try writer.finish()
        try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 2, solid: false, filter: "BCJ")
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }
}
