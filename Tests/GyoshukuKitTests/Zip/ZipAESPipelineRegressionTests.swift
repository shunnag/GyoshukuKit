import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipAESPipelineRegressionTests: XCTestCase {
    private let methods: [CompressionMethod] = [.bzip2, .lzma, .xz, .zstd, .ppmd]
    private let password = EncryptionTestSupport.password

    func testLargeHeuristicStoredAESInterleavesWithDataAddsAtBothFinishPaths() throws {
        let root = try TestSupport.directory("zip-aes-pipeline-data")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = [ExpectedEntry(name: "lead.txt", data: small)] + interleavedItems
        for method in methods {
            for finishAdditions in [false, true] {
                var baseline: Data?
                for threads in [1, 4] {
                    let url = root.appendingPathComponent("\(method)-\(finishAdditions)-\(threads).zip")
                    let salts = Salts()
                    let writer = try makeWriter(url, method: method, threads: threads, salts: salts)
                    for item in items {
                        try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                    }
                    if finishAdditions { try writer.finishAdditions(progress: nil) }
                    try writer.finish()
                    XCTAssertEqual(salts.count, items.count)
                    try verify(url, items: items, baseline: &baseline,
                        context: "\(method), finishAdditions=\(finishAdditions), threads=\(threads)")
                }
            }
        }
    }

    func testLargeHeuristicStoredAESInterleavesInsideDirectAndBatchFolderAdds() throws {
        let root = try TestSupport.directory("zip-aes-pipeline-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = interleavedItems
        let folder = try makeFolder(root, files: files)
        let items = [ExpectedEntry(name: "lead.txt", data: small)] + folderItems(files)
            + [ExpectedEntry(name: "tail.txt", data: small)]
        for method in methods {
            for batch in [false, true] {
                var baseline: Data?
                for threads in [1, 4] {
                    try resetDates(folder, files: files)
                    let url = root.appendingPathComponent("\(method)-\(batch)-\(threads).zip")
                    let salts = Salts()
                    let writer = try makeWriter(url, method: method, threads: threads, salts: salts)
                    try writer.add(data: small, as: "lead.txt", modificationDate: TestSupport.date)
                    if batch {
                        // directory の一括追加は fallBackToDisk から同じ再帰追加へ進む。
                        try writer.add([.init(path: "files", source: .contents(of: folder))], events: nil)
                    } else { try writer.add(contentsOf: folder, as: "files") }
                    try writer.add(data: small, as: "tail.txt", modificationDate: TestSupport.date)
                    try writer.finish()
                    XCTAssertEqual(salts.count, files.count + 2)
                    try verify(url, items: items, baseline: &baseline,
                        context: "\(method), batch=\(batch), threads=\(threads)")
                }
            }
        }
    }

    func testUpdaterPreservesAESOrderForDataAndBatchFolderAdds() throws {
        let root = try TestSupport.directory("zip-aes-pipeline-updater")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = interleavedItems
        let folder = try makeFolder(root, files: files)
        let original = ExpectedEntry(name: "original.txt", data: Data("plain original\n".utf8))
        let source = root.appendingPathComponent("source.zip")
        let writer = try ArchiveWriter.create(url: source)
        try writer.add(data: original.data, as: original.name, modificationDate: TestSupport.date)
        try writer.finish()
        for method in methods {
            for batchFolder in [false, true] {
                var baseline: Data?
                let items = [original, ExpectedEntry(name: "lead.txt", data: small)]
                    + (batchFolder ? folderItems(files) : files)
                    + [ExpectedEntry(name: "tail.txt", data: small)]
                for threads in [1, 4] {
                    try resetDates(folder, files: files)
                    let url = root.appendingPathComponent("\(method)-\(batchFolder)-\(threads).zip")
                    try FileManager.default.copyItem(at: source, to: url)
                    let salts = Salts()
                    try EncryptionPrimitives.$testingRandomBytes.withValue({ try salts.next($0) }) {
                        let updater = try ArchiveUpdater.open(url: url, options: options(method, threads: threads))
                        try updater.add(data: small, as: "lead.txt", modificationDate: TestSupport.date)
                        if batchFolder {
                            try updater.add([.init(path: "files", source: .contents(of: folder))], events: nil)
                        } else {
                            for item in files {
                                try updater.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                            }
                        }
                        try updater.add(data: small, as: "tail.txt", modificationDate: TestSupport.date)
                        try updater.commit()
                    }
                    XCTAssertEqual(salts.count, files.count + 2)
                    try verify(url, items: items, baseline: &baseline,
                        context: "\(method), batchFolder=\(batchFolder), threads=\(threads)")
                }
            }
        }
    }

    func testLoneAESLZMAEntryKeepsParallelFinderAtFinish() throws {
        let root = try TestSupport.directory("zip-aes-lone-lzma-finder")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ExpectedEntry(name: "lone.txt", data: Data(repeating: 0x41, count: 256 << 10))
        var baseline: Data?
        for threads in [1, 8] {
            let url = root.appendingPathComponent("\(threads).zip")
            let before = LZMAMatchFinderPipeline.testingWorkerCounts
            let salts = Salts()
            let writer = try makeWriter(url, method: .lzma, threads: threads, salts: salts)
            try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
            // 待機中は codec を始めず、finish の直接書込で指定の finder 並列数を使う。
            if threads > 1 {
                XCTAssertEqual(LZMAMatchFinderPipeline.testingWorkerCounts.starts, before.starts)
                XCTAssertEqual(salts.count, 0)
            }
            try writer.finish()
            let after = LZMAMatchFinderPipeline.testingWorkerCounts
            XCTAssertEqual(after.starts - before.starts, threads == 1 ? 0 : 1)
            XCTAssertEqual(after.live, before.live)
            XCTAssertEqual(salts.count, 1)
            try verify(url, items: [item], baseline: &baseline, context: "threads=\(threads)")
        }
    }

    private var small: Data { Data(repeating: 0x41, count: 100 << 10) }

    private var interleavedItems: [ExpectedEntry] {
        // 12 個の block は四枠の窓を越え、先頭の AES header を確実に出力させる。
        [ExpectedEntry(name: "0-big.jpg", data: Data(repeating: 0x39, count: 12 << 20)),
         ExpectedEntry(name: "a.txt", data: small), ExpectedEntry(name: "b.txt", data: small),
         ExpectedEntry(name: "c-big.jpg", data: Data(repeating: 0x57, count: DeflateBlock.size + 17)),
         ExpectedEntry(name: "d.txt", data: small), ExpectedEntry(name: "e.txt", data: small)]
    }

    private func options(_ method: CompressionMethod, threads: Int) -> WriterOptions {
        let options = WriterOptions(compressionMethod: method, password: password, compressionThreads: threads)
        if threads > 1 { XCTAssertGreaterThan(EntryCompressionConfiguration(options: options).threads, 1) }
        return options
    }

    private func makeWriter(_ url: URL, method: CompressionMethod, threads: Int, salts: Salts) throws -> ArchiveWriter {
        try ArchiveWriter.create(url: url, format: .zip, options: options(method, threads: threads),
            zipSalt: { try salts.next(16) }, lzmaChunkSize: nil)
    }

    private func makeFolder(_ root: URL, files: [ExpectedEntry]) throws -> URL {
        let folder = root.appendingPathComponent("source-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in files { try item.data.write(to: folder.appendingPathComponent(item.name)) }
        return folder
    }

    private func resetDates(_ folder: URL, files: [ExpectedEntry]) throws {
        for item in files { try AdditionProgressTestSupport.timestamp(folder.appendingPathComponent(item.name)) }
        try AdditionProgressTestSupport.timestamp(folder)
    }

    private func folderItems(_ files: [ExpectedEntry]) -> [ExpectedEntry] {
        [ExpectedEntry(name: "files/", kind: .directory)] + files.map {
            var item = $0
            item.name = "files/" + item.name
            return item
        }
    }

    private func verify(_ url: URL, items: [ExpectedEntry], baseline: inout Data?, context: String) throws {
        try EncryptionTestSupport.verify(url, items: items, password: password) {
            $0.kind == .file && $0.name != "original.txt"
        }
        let bytes = try Data(contentsOf: url)
        if let baseline { XCTAssertEqual(bytes, baseline, context) } else { baseline = bytes }
        try FileManager.default.removeItem(at: url)
    }

    private final class Salts: @unchecked Sendable {
        private let lock = NSLock()
        private let thread = Thread.current
        private(set) var count = 0

        func next(_ size: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            XCTAssertTrue(Thread.current === thread)
            XCTAssertEqual(size, 16)
            defer { count += 1 }
            return Data((0..<size).map { UInt8(truncatingIfNeeded: count * 19 + $0) })
        }
    }
}
