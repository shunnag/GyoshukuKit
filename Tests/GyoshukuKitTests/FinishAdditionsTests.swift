import Foundation
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class FinishAdditionsTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport

    func testBytesAndBoundsForLargeAndSmallInputsWithEncryption() throws {
        try ArchiveUpdater.$testingRandomBytes.withValue({ Data(repeating: 17, count: $0) }) {
        try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 23, count: 16) }) {
            for format in S.formats {
                for encryption in 0..<(format == .zip ? 3 : format == .sevenZip ? 2 : 1) {
                    let root = try ZipTestSupport.directory("p6-finish-\(format)-\(encryption)")
                    var expected: Data?
                    for threads in [1, 8] {
                        for drain in [false, true] {
                            let output = root.appendingPathComponent("\(threads)-\(drain)")
                            let options = WriterOptions(password: encryption == 0 ? nil : "password",
                                zipEncryption: encryption == 2 ? .zipCrypto : .aes256,
                                encryptsSevenZipHeaders: format == .sevenZip && encryption == 1,
                                compressionThreads: threads)
                            let writer = try ArchiveWriter.create(url: output, format: format, options: options,
                                deflateBlockSize: 64 * 1024, zipSalt: { Data(repeating: 19, count: 16) },
                                lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                            try ParallelDeflateBzip2WriterTests.addProgressFixture(to: writer)
                            try writer.add(data: Data(repeating: 0x61, count: 40 * S.mib), as: "large40", modificationDate: ZipTestSupport.date)
                            if threads == 8 && (format == .tarXZ || format == .sevenZip) {
                                XCTAssertGreaterThan(writer.pendingInputBytes, 0)
                            }
                            XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: format))
                            for index in 0..<200 {
                                try writer.add(data: Data(repeating: UInt8(index), count: 1023), as: "small-\(index)", modificationDate: ZipTestSupport.date)
                                XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: format))
                            }
                            if drain {
                                let pending = writer.pendingInputBytes, session = S.Session()
                                try writer.finishAdditions(progress: session.record)
                                session.check(total: pending)
                                XCTAssertEqual(writer.pendingInputBytes, 0)
                                XCTAssertLessThanOrEqual(pending, options.maximumPendingInputBytes(for: format))
                                let again = S.Session()
                                try writer.finishAdditions(progress: again.record)
                                again.check(total: 0)
                                assertClosed(writer, disk: output)
                            }
                            try writer.finish()
                            let bytes = try Data(contentsOf: output)
                            if let expected { XCTAssertEqual(bytes, expected, "\(format) encryption=\(encryption) threads=\(threads) drain=\(drain)") }
                            else { expected = bytes }
                        }
                    }
                }
            }
        } }
    }

    private func assertClosed(_ writer: ArchiveWriter, disk: URL) {
        let operations: [() throws -> Void] = [
            { try writer.add(contentsOf: disk, as: "bad") },
            { try writer.add(contentsOf: disk, as: "bad", progress: { _ in XCTFail("closed add callback") }) },
            { try writer.add(contentsOf: disk, as: "bad", ownerIDs: nil) },
            { try writer.add(data: Data(), as: "bad") },
            { try writer.addDirectory("bad") },
            { try writer.addEntry(path: "bad", mode: 0o100644, size: 0, date: ZipTestSupport.date, atime: nil, owners: nil) { _ in Data() } }
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
        }
    }

    func testLargeLZMA2SessionReportsPendingInputImmediatelyAfterAdd() throws {
        for format in [GyoshukuKit.ArchiveFormat.tarXZ, .sevenZip] {
            let root = try ZipTestSupport.directory("p6-large-pending-\(format)")
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("output"), format: format, options: S.options)
            try writer.add(data: Data(repeating: 0x61, count: 40 * S.mib), as: "large", modificationDate: ZipTestSupport.date)
            let session = S.Session()
            try writer.finishAdditions(progress: session.record)
            let total = try XCTUnwrap(session.updates.first?.totalBytes)
            XCTAssertGreaterThan(total, 0)
            XCTAssertLessThanOrEqual(total, S.options.maximumPendingInputBytes(for: format))
            session.check(total: total)
            XCTAssertGreaterThan(session.updates.count, 2)
            try writer.finish()
        }
    }

    func testEveryUpdaterPreservesBytesStrategyAndRemainsEditableAfterClosing() throws {
        for format in S.formats {
            let root = try ZipTestSupport.directory("p6-updater-close-\(format)")
            let source = try S.source(root, format: format)
            let disk = try S.file(root, "disk", size: 9 * S.mib + 1)
            var expected: Data?, strategy: String?
            for drain in [false, true] {
                let output = root.appendingPathComponent("\(drain)")
                let editor = try S.editor(source, output: output, format: format)
                XCTAssertFalse(editor.readsAdditionsDuringCommit)
                try S.timestamp(disk)
                try editor.add(contentsOf: disk, as: "added")
                if drain {
                    let session = S.Session()
                    try editor.finishAdditions(progress: session.record)
                    let total = try XCTUnwrap(session.updates.first?.totalBytes)
                    session.check(total: total)
                    XCTAssertLessThanOrEqual(total, S.options.maximumPendingInputBytes(for: format))
                    let scans = (editor as? ArchiveUpdater)?.nameCheckScanCount
                    for operation: () throws -> Void in [
                        { try editor.add(contentsOf: disk, as: "bad") },
                        { try editor.add(contentsOf: disk, as: "bad", ownerIDs: nil, progress: nil) },
                        { try editor.add(data: Data(), as: "bad", modificationDate: nil, permissions: nil) },
                        { try editor.addDirectory("bad") }
                    ] {
                        XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
                    }
                    XCTAssertEqual((editor as? ArchiveUpdater)?.nameCheckScanCount, scans)
                    let again = S.Session()
                    try editor.finishAdditions(progress: again.record)
                    again.check(total: 0)
                }
                try editor.rename(entryAt: 0, to: "renamed")
                try editor.remove(entriesAt: [])
                try editor.commit()
                let bytes = try Data(contentsOf: output), actualStrategy = S.strategy(editor)
                if let expected { XCTAssertEqual(bytes, expected); XCTAssertEqual(actualStrategy, strategy) }
                else { expected = bytes; strategy = actualStrategy }
            }
        }
    }

    func testEmptyFinishAndFinishBeforeAnyAddition() throws {
        for format in S.formats {
            let root = try ZipTestSupport.directory("p6-close-empty-\(format)")
            let source = try S.source(root, format: format)
            for rewrite in [false, true] {
                let output = root.appendingPathComponent("\(rewrite)")
                let editor = try S.editor(source, output: output, format: format, rewrite: rewrite)
                for _ in 0..<2 {
                    let session = S.Session()
                    try editor.finishAdditions(progress: session.record)
                    session.check(total: 0)
                }
                XCTAssertThrowsError(try editor.addDirectory("bad"))
                try editor.commit()
            }
        }
    }

    func testEmptyWriterMatchesWithoutDrain() throws {
        for format in S.formats {
            let root = try ZipTestSupport.directory("p6-empty-writer-\(format)")
            var expected: Data?
            for drain in [false, true] {
                let output = root.appendingPathComponent("\(drain)")
                let writer = try ArchiveWriter.create(url: output, format: format, options: S.options)
                if drain {
                    let session = S.Session()
                    try writer.finishAdditions(progress: session.record)
                    session.check(total: 0)
                }
                try writer.finish()
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
            }
        }
    }

    func testClosedZIPDoesNotSpendLiveNameCheckBudget() throws {
        try ArchiveUpdater.$testingNameCheckMinimumEntries.withValue(0) {
            let root = try ZipTestSupport.directory("p6-closed-live-names")
            let source = try S.source(root, format: .zip)
            let output = root.appendingPathComponent("output.zip")
            let editor = try ArchiveUpdater.open(url: source, output: output)
            try editor.add(data: Data([1]), as: "added", modificationDate: ZipTestSupport.date)
            XCTAssertTrue(editor.writerUsesLiveNameCheck)
            XCTAssertEqual(editor.nameCheckScanCount, 1)
            try editor.finishAdditions(progress: nil)
            for _ in 0..<6 {
                XCTAssertThrowsError(try editor.add(contentsOf: source, as: "bad")) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
                XCTAssertThrowsError(try editor.add(data: Data(), as: "bad")) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
                XCTAssertThrowsError(try editor.addDirectory("bad")) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
            }
            XCTAssertEqual(editor.nameCheckScanCount, 1)
            XCTAssertTrue(editor.writerUsesLiveNameCheck)
            try editor.commit()
        }
    }

    func testDrainCallbackFailureCleansEveryUpdater() throws {
        for format in S.formats {
            for cancel in [false, true] {
                let root = try ZipTestSupport.directory("p6-drain-error-\(format)-\(cancel)")
                let source = try S.source(root, format: format)
                let bytes = try Data(contentsOf: source), inode = try ZipP1Support.info(source).st_ino
                let work = try TarP2Support.work(root), output = work.appendingPathComponent("output")
                let editor = try S.editor(source, output: output, format: format)
                for index in 0..<8 {
                    try editor.add(data: Data(repeating: 0x61, count: S.mib), as: "new-\(index)", modificationDate: ZipTestSupport.date, permissions: nil)
                }
                var calls = 0
                XCTAssertThrowsError(try editor.finishAdditions(progress: { p in
                    calls += 1
                    if p.completedBytes > 0 || p.totalBytes == 0 {
                        if cancel { throw CancellationError() }
                        throw S.Failure.callback
                    }
                })) { error in
                    if cancel { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? S.Failure, .callback) }
                }
                XCTAssertGreaterThan(calls, 0)
                XCTAssertThrowsError(try editor.commit())
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
                XCTAssertEqual(try Data(contentsOf: source), bytes)
                XCTAssertEqual(try ZipP1Support.info(source).st_ino, inode)
            }
        }
    }

    func testP14BoundAndDrainAccountsForLightBlocksAndBufferedMember() throws {
        for threads in [1, 8] {
            let options = WriterOptions(compressionThreads: threads)
            let expected = UInt64(threads * 16 * S.mib + 4 * S.mib + (threads > 1 ? (threads + 1) * 64 * 1024 : 0))
            XCTAssertEqual(options.maximumPendingInputBytes(for: .tarXZ), expected)
            let compressor = try ParallelXZCompressor(threads: threads)
            // Alternating small header groups, full pieces and a final packed member exercise both windows.
            for _ in 0..<12 {
                compressor.beginMember(headerLength: 512, bodyLength: UInt64(16 * S.mib))
                try compressor.write(Data(count: 512), finish: false) { _ in }
                try compressor.write(Data(repeating: 0x61, count: 16 * S.mib), finish: false) { _ in }
            }
            compressor.beginMember(headerLength: 512, bodyLength: 512)
            try compressor.write(Data(count: 1024), finish: false) { _ in }
            let pending = compressor.pendingInputBytes
            XCTAssertLessThanOrEqual(pending, expected)
            var drained: UInt64 = 0
            try compressor.finishAdditions(didEmit: { drained += $0 }) { _ in }
            XCTAssertEqual(drained, pending)
            XCTAssertEqual(compressor.pendingInputBytes, 0)
        }
    }
}
