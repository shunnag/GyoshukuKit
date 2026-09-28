import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class BatchAdditionEquivalenceTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport
    private typealias B = BatchAdditionTestSupport

    func testWriterBytesAllFormatsThreadsEncryptionAndThresholds() throws {
        let root = try ZipTestSupport.directory("p7-writer-matrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try B.fixture(root)
        try EncryptionPrimitives.$testingRandomBytes.withValue({ Data(repeating: 17, count: $0) }) {
        try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 23, count: 16) }) {
            for format in S.formats {
                let items = B.applicable(fixture, format: format)
                for encryption in 0..<(format == .zip ? 3 : format == .sevenZip ? 2 : 1) {
                    for threads in [1, 4, 8] {
                        for blockSize in [65536, DeflateBlock.size] {
                            let options = WriterOptions(password: encryption == 0 ? nil : "password",
                                zipEncryption: encryption == 2 ? .zipCrypto : .aes256,
                                encryptsSevenZipHeaders: format == .sevenZip && encryption == 1,
                                compressionThreads: threads)
                            var expected: Data?
                            for batch in [false, true] {
                                try B.resetDates(items)
                                let output = root.appendingPathComponent("\(format)-\(encryption)-\(threads)-\(blockSize)-\(batch)")
                                let writer = try ArchiveWriter.create(url: output, format: format, options: options,
                                    deflateBlockSize: blockSize, zipSalt: { Data(repeating: 19, count: 16) },
                                    lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                                if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                                try writer.finishAdditions(progress: nil)
                                try writer.finish()
                                let bytes = try Data(contentsOf: output)
                                if let expected { XCTAssertEqual(bytes, expected, "\(format) encryption=\(encryption) threads=\(threads) block=\(blockSize)") }
                                else { expected = bytes }
                                try FileManager.default.removeItem(at: output)
                            }
                        }
                    }
                }
            }
        } }
    }

    func testUpdaterAndRewriterBothPlacementsCommitBytes() throws {
        let root = try ZipTestSupport.directory("p7-editors")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try B.fixture(root)
        for format in S.formats {
            let source = try S.source(root, format: format)
            let items = B.applicable(fixture, format: format)
            for kind in ["update", "beginning", "end"] {
                var options = S.options
                options.additionPlacement = kind == "beginning" ? .beginning : .end
                var expected: Data?
                for batch in [false, true] {
                    try B.resetDates(items)
                    let output = root.appendingPathComponent("\(format)-\(kind)-\(batch)")
                    let editor = try S.editor(source, output: output, format: format, options: options, rewrite: kind != "update")
                    var events: [ArchiveAdditionEvent] = []
                    if batch { try editor.add(items, events: { events.append($0) }) }
                    else { try B.singles(editor, items) }
                    if kind == "end", batch {
                        XCTAssertEqual(events.filter { if case .progress(_, let p) = $0 { return p.totalBytes != 0 }; return false }.count, 0)
                    }
                    try editor.finishAdditions(progress: nil)
                    try editor.commit()
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertEqual(bytes, expected, "\(format) \(kind)") } else { expected = bytes }
                }
            }
        }
    }

    func testLiveNameBudgetsPromoteWithQueuedNamesAndMatchSingles() throws {
        let root = try ZipTestSupport.directory("p7-name-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try S.source(root, format: .zip)
        let original = try B.small(root, count: 10)
        for budget in [0, 4, Int.max] {
            for duplicate in [nil, 2, 8] as [Int?] {
                var items = original
                if let duplicate { items[duplicate].path = duplicate == 2 ? "base" : items[0].path }
                var scans: [Int] = [], bytes: [Data] = []
                try ArchiveUpdater.$testingNameCheckMinimumEntries.withValue(0) {
                try ArchiveUpdater.$testingNameCheckBudget.withValue(budget) {
                    for batch in [false, true] {
                        try B.resetDates(items)
                        let output = root.appendingPathComponent("\(budget)-\(duplicate ?? -1)-\(batch).zip")
                        let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(compressionThreads: 8))
                        do {
                            if batch { try updater.add(items, events: nil) } else { try B.singles(updater, items) }
                            XCTAssertNil(duplicate)
                            try updater.commit()
                            bytes.append(try Data(contentsOf: output))
                        } catch {
                            XCTAssertNotNil(duplicate)
                            if batch {
                                let failure = try XCTUnwrap(error as? ArchiveAdditionError)
                                XCTAssertEqual(failure.index, duplicate)
                                XCTAssertEqual(failure.underlying as? WriterError, .duplicatePath(items[duplicate!].path))
                            } else { XCTAssertEqual(error as? WriterError, .duplicatePath(items[duplicate!].path)) }
                        }
                        scans.append(updater.nameCheckScanCount)
                    }
                } }
                XCTAssertEqual(scans[0], scans[1])
                if duplicate == nil { XCTAssertEqual(bytes[0], bytes[1]) }
            }
        }
    }

    func testRecursiveFallbackAndOwnersAndLHASymlink() throws {
        let root = try ZipTestSupport.directory("p7-recursive")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try B.fixture(root, full: false)
        for format in S.formats where format != .lha {
            let ids: ArchiveOwnerIDs? = format == .sevenZip ? nil : .init(user: 23, group: 47)
            let items = [ArchiveAddition(path: "tree", source: .contents(of: root.appendingPathComponent("input")), ownerIDs: ids)]
            var bytes: [Data] = []
            for batch in [false, true] {
                try B.resetDates(fixture)
                try S.timestamp(root.appendingPathComponent("input"))
                let output = root.appendingPathComponent("recursive-\(format)-\(batch)")
                let writer = try ArchiveWriter.create(url: output, format: format)
                if batch { try writer.add(items, events: { _ in }) } else { try B.singles(writer, items) }
                try writer.finish(); bytes.append(try Data(contentsOf: output))
            }
            XCTAssertEqual(bytes[0], bytes[1])
        }
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("bad.lha"), format: .lha)
        XCTAssertThrowsError(try writer.add([fixture.first { $0.path == "link0" }!], events: nil)) {
            let error = $0 as? ArchiveAdditionError
            XCTAssertEqual(error?.index, 0)
            XCTAssertEqual(error?.underlying as? WriterError, .unsupportedFileType("link0"))
        }
    }
}
