import Foundation
import Synchronization
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

    func testInnerWorkerBudgetAndAbortJoin() throws {
        struct Activity { var running = 0, peak = 0, started = 0 }
        let root = try TestSupport.directory("7z-inner-worker-budget")
        let data = Data(repeating: 0x61, count: 256 << 10)
        for method: SevenZipCompressionMethod in [.lzma2, .deflate] {
            for abort in [false, true] {
                let activity = Mutex(Activity())
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: .on(blockSize: UInt64(data.count)), compressionThreads: 4)
                let writer = SevenZipBlockWriter(options: options, directory: root, chunkSize: 128 << 10, workerActivity: { began in
                    activity.withLock {
                        $0.running += began ? 1 : -1
                        if began { $0.started += 1; $0.peak = max($0.peak, $0.running) }
                    }
                    if began {
                        started.signal()
                        if abort { XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
                        else { Thread.sleep(forTimeInterval: 0.02) }
                    }
                })
                var position: UInt64 = 0
                let write: (Data) -> Void = { position += UInt64($0.count) }
                for index in 0..<(abort ? 2 : 8) {
                    var offset = 0
                    try writer.add(name: "block-\(index)", mode: 0o100644, size: UInt64(data.count), date: TestSupport.date,
                        read: { count in
                            let end = min(data.count, offset + count)
                            defer { offset = end }
                            return data.subdata(in: offset..<end)
                        }, position: { position }, write: write)
                    XCTAssertGreaterThan(writer.assignedThreads, 0)
                    XCTAssertLessThanOrEqual(writer.assignedThreads, 4)
                }
                if abort {
                    // 動作中のcodecを確保してから取消し、join後の終了を検査する。
                    XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
                    XCTAssertGreaterThan(activity.withLock { $0.running }, 0)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                        for _ in 0..<4 { release.signal() }
                    }
                    writer.abandon()
                } else { try writer.flush(position: { position }, write: write) }
                XCTAssertEqual(writer.assignedThreads, 0)
                XCTAssertEqual(writer.pendingInputBytes, 0)
                XCTAssertEqual(activity.withLock { $0.running }, 0)
                print("7Z INNER \(method) abort=\(abort) peak=\(activity.withLock { $0.peak }) assigned=\(writer.assignedThreads)")
                XCTAssertLessThanOrEqual(activity.withLock { $0.peak }, 4)
                if !abort {
                    XCTAssertEqual(activity.withLock { $0.started }, 16)
                    XCTAssertGreaterThan(activity.withLock { $0.peak }, 1)
                }
            }
        }
    }

    func testThrowingBlockEmitCannotReturnThreadsTwice() throws {
        let root = try TestSupport.directory("7z-inner-worker-error")
        let data = Data(repeating: 0x61, count: 256 << 10)
        let options = WriterOptions(sevenZipMethod: .deflate, sevenZipSolid: .on(blockSize: UInt64(data.count)), compressionThreads: 4)
        let writer = SevenZipBlockWriter(options: options, directory: root, chunkSize: 128 << 10)
        defer { writer.abandon() }
        for index in 0..<2 {
            var offset = 0
            try writer.add(name: "block-\(index)", mode: 0o100644, size: UInt64(data.count), date: TestSupport.date,
                read: { count in
                    let end = min(data.count, offset + count)
                    defer { offset = end }
                    return data.subdata(in: offset..<end)
                }, position: { 0 }, write: { _ in XCTFail("early emit") })
        }
        XCTAssertEqual(writer.assignedThreads, 4)
        var calls = 0
        let fail: (Data) throws -> Void = { _ in calls += 1; throw WriterError.compression(-77) }
        XCTAssertThrowsError(try writer.flush(position: { 0 }, write: fail))
        XCTAssertEqual(writer.assignedThreads, 2)
        XCTAssertThrowsError(try writer.flush(position: { 0 }, write: fail))
        XCTAssertEqual(writer.assignedThreads, 2)
        XCTAssertEqual(calls, 1)
        writer.abandon()
        XCTAssertEqual(writer.assignedThreads, 0)
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
