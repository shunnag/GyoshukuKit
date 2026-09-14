import Foundation
import KaitoKit
import XCTest
import Darwin
@testable import GyoshukuKit

@MainActor
final class LHALifecycleTests: XCTestCase {
    func testOptionsExclusiveCreateAndFinishedState() throws {
        let directory = try ZipTestSupport.directory("lha-options")
        let url = directory.appendingPathComponent("archive.lzh")
        for options in [WriterOptions(deflateLevel: 10), WriterOptions(preserveOwnerIDs: true), WriterOptions(preserveMacOSMetadata: true)] {
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .lha, options: options))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        // ZIP 専用の圧縮 option / 拡張子 heuristic が LHA の方式を変えないことも確認する。
        let writer = try ArchiveWriter.create(url: url, format: .lha, options: WriterOptions(compressionMethod: .stored))
        let payload = Data(repeating: 0xAA, count: 10_000)
        try writer.add(data: payload, as: "payload.zip", modificationDate: ZipTestSupport.date)
        try writer.finish()
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(try LHABytes(saved).members.first?.method, "-lh5-")
        XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .lha))
        XCTAssertThrowsError(try writer.addDirectory("late"))
        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try LHATestSupport.verify(url, expected: [.init(name: "payload.zip", data: payload)])
    }

    func testUnfinishedWriterAndOutputAsSourceAreRemoved() throws {
        let directory = try ZipTestSupport.directory("lha-unfinished")
        let url = directory.appendingPathComponent("archive.lzh")
        let alias = directory.appendingPathComponent("alias.lzh")
        do {
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try writer.add(data: Data([1]), as: "unfinished")
            try FileManager.default.linkItem(at: url, to: alias)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: alias))
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        XCTAssertThrowsError(try writer.add(contentsOf: url, as: "self"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailurePreservesReplacementAndInvalidatesOldInode() throws {
        let directory = try ZipTestSupport.directory("lha-replaced-output")
        let url = directory.appendingPathComponent("archive.lzh")
        let moved = directory.appendingPathComponent("moved.lzh")
        let alias = directory.appendingPathComponent("alias.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        try writer.add(data: Data([1]), as: "valid")
        try FileManager.default.linkItem(at: url, to: alias)
        try FileManager.default.moveItem(at: url, to: moved)
        let replacement = Data("someone else's file".utf8)
        try replacement.write(to: url)
        XCTAssertThrowsError(try writer.add(contentsOf: directory.appendingPathComponent("missing"), as: "missing"))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try Data(contentsOf: moved).count, 0)
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: moved))
        XCTAssertThrowsError(try writer.finish())
    }

    func testSymlinksAreRefusedWithoutFollowingThem() throws {
        let directory = try ZipTestSupport.directory("lha-symlink")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nonexistent-target")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        XCTAssertThrowsError(try writer.add(contentsOf: link, as: "link")) {
            XCTAssertEqual($0 as? WriterError, .unsupportedFileType("link"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInvalidMetadataIsRejectedBeforeInputCallbackOrHeaderWrite() throws {
        for (index, name) in ["🗂.txt", "한글/file.txt"].enumerated() {
            try withWriter("lha-preflight-\(index)") { writer, output in
                var reads = 0
                XCTAssertThrowsError(try writer.add(name: name, mode: 0o100644, size: 1, date: ZipTestSupport.date) { _ in
                    reads += 1
                    return Data([1])
                })
                XCTAssertEqual(reads, 0)
                XCTAssertEqual(try output.offset(), 0)
            }
        }
        try withWriter("lha-size-preflight") { writer, output in
            var reads = 0
            XCTAssertThrowsError(try writer.add(name: "oversize", mode: 0o100644, size: UInt64(UInt32.max) + 1, date: ZipTestSupport.date) { _ in
                reads += 1
                return Data()
            }) { XCTAssertEqual($0 as? WriterError, .sizeOverflow) }
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(try output.offset(), 0)
        }
    }

    func testShortOversizedAndGrowingInputFailBeforeHeaderWrite() throws {
        for (index, chunks) in [[Data()], [Data([1, 2])], [Data([1]), Data([2])]].enumerated() {
            try withWriter("lha-changed-input-\(index)") { writer, output in
                var index = 0
                XCTAssertThrowsError(try writer.add(name: "changed", mode: 0o100644, size: 1, date: ZipTestSupport.date) { _ in
                    defer { index += 1 }
                    return chunks[index]
                }) { XCTAssertEqual($0 as? WriterError, .sourceChanged("changed")) }
                XCTAssertEqual(try output.offset(), 0)
            }
        }
    }

    func testPublicCancellationMidWriteInvalidatesCompletedMembersAndAliases() async throws {
        let directory = try ZipTestSupport.directory("lha-cancel")
        let source = directory.appendingPathComponent("large-source")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: source) }
        let url = directory.appendingPathComponent("archive.lzh")
        let alias = directory.appendingPathComponent("alias.lzh")
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try writer.add(data: Data("completed first member".utf8), as: "first")
            try writer.add(contentsOf: source, as: "large")
            try writer.finish()
        }
        var started = false
        for _ in 0..<10_000 {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > 50 {
                started = true
                try FileManager.default.linkItem(at: url, to: alias)
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        XCTAssertTrue(started, "cancel after a real member has reached the output")
        do { try await task.value; XCTFail("cancelled write succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: url))
        XCTAssertThrowsError(try ArchiveReader.open(url: alias))
        let lhasa = try LHATestSupport.run(LHATestSupport.lhasa, ["t", url.path], in: directory, log: "lha-cancelled")
        XCTAssertTrue(lhasa.text.contains("No such file or directory"), lhasa.text)
        let seven = try LHATestSupport.run(LHATestSupport.sevenZip, ["t", alias.path], in: directory, log: "7zz-cancelled-alias")
        XCTAssertTrue(seven.text.contains("Cannot open the file as archive"), seven.text)
        XCTAssertFalse(seven.text.contains("Everything is Ok"), seven.text)
    }

    func testCancellationBeforeCreateAndFinish() async throws {
        let directory = try ZipTestSupport.directory("lha-cancel-finish")
        let url = directory.appendingPathComponent("archive.lzh")
        let alias = directory.appendingPathComponent("alias.lzh")
        let task = Task {
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try writer.add(data: Data([1]), as: "complete-member")
            try FileManager.default.linkItem(at: url, to: alias)
            withUnsafeCurrentTask { $0?.cancel() }
            try writer.finish()
        }
        do { try await task.value; XCTFail("cancelled finish succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try ArchiveWriter.create(url: url, format: .lha)
        }
        do { try await before.value; XCTFail("cancelled create succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func withWriter(_ label: String, body: (LHAWriter, FileHandle) throws -> Void) throws {
        let directory = try ZipTestSupport.directory(label)
        let url = directory.appendingPathComponent("archive.lzh")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        var info = stat()
        XCTAssertEqual(fstat(output.fileDescriptor, &info), 0)
        let writer = LHAWriter(output: output, url: url, identity: (info.st_dev, info.st_ino))
        defer { writer.abort(); try? output.close() }
        try body(writer, output)
    }
}
