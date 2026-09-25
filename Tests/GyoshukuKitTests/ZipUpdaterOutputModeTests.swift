import Foundation
import Darwin
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipUpdaterOutputModeTests: XCTestCase {
    private func setup(_ label: String) throws -> (URL, URL, URL) {
        let directory = try ZipTestSupport.directory("p1-output-" + label)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory)
        let parent = directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (source, parent.appendingPathComponent("output.zip"), parent)
    }

    func testOutputMatchesReplaceAndPreservesSourceAttributesWithSnapshotReads() throws {
        let (source, output, parent) = try setup("attributes")
        for key in ["com.apple.quarantine", "org.gyoshuku.test"] {
            let bytes = Data((key == "com.apple.quarantine" ? "0081;65000000;GyoshukuKit;" : "custom").utf8)
            XCTAssertEqual(bytes.withUnsafeBytes { setxattr(source.path, key, $0.baseAddress, $0.count, 0, 0) }, 0)
        }
        XCTAssertEqual(chflags(source.path, UInt32(UF_NODUMP)), 0)
        defer { _ = chflags(source.path, 0) }
        let before = try Data(contentsOf: source), info = try ZipP1Support.info(source)
        let replacement = source.deletingLastPathComponent().appendingPathComponent("replace.zip")
        try FileManager.default.copyItem(at: source, to: replacement)
        let replace = try ArchiveUpdater.open(url: replacement)
        try replace.remove(entriesAt: [0]); try replace.commit()
        let events = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(events.read) {
            let updater = try ArchiveUpdater.open(url: source, output: output)
            let snapshots = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            XCTAssertEqual(snapshots.count, 1, "APFS must create one source snapshot")
            let snapshot = try XCTUnwrap(snapshots.first)
            XCTAssertEqual(try ZipP1Support.info(snapshot).st_flags, 0)
            let inode = try ZipP1Support.info(snapshot).st_ino
            try updater.remove(entriesAt: [0]); try updater.commit()
            XCTAssertTrue(events.events.allSatisfy { $0.inode == inode })
        }
        try ZipP1Support.assertEqualFiles(output, replacement)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let after = try ZipP1Support.info(source)
        XCTAssertEqual(info.st_ino, after.st_ino)
        XCTAssertEqual(info.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(info.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try ZipP1Support.info(output).st_mode & 0o7777, 0o600)
        XCTAssertEqual(try ZipP1Support.info(output).st_flags, 0)
        for key in ["com.apple.quarantine", "org.gyoshuku.test"] {
            func value(_ url: URL) -> Data {
                let count = getxattr(url.path, key, nil, 0, 0, 0)
                var result = Data(count: max(count, 0))
                _ = result.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }
                return result
            }
            XCTAssertEqual(value(source), value(output))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["output.zip"])
        for fd in 0..<min(getdtablesize(), 4096) {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &path) == 0 {
                XCTAssertNotEqual(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), output.path, "output descriptor must be closed")
            }
        }
    }

    func testSnapshotHelperAcceptsNonZIPBytesAndTarExtension() throws {
        let (source, _, parent) = try setup("format-independent")
        let raw = source.deletingLastPathComponent().appendingPathComponent("source.tar")
        let contents = Data(repeating: 0, count: 1024)
        try contents.write(to: raw)
        do {
            let snapshot = try ArchiveSourceSnapshot(url: raw, directory: parent, pathExtension: "tar")
            XCTAssertEqual(snapshot.snapshot?.url.pathExtension, "tar")
            XCTAssertEqual(try snapshot.source.bytes(at: 0, count: contents.count), contents)
            try snapshot.checkUnchanged()
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testImmutableSourceIsRefusedBeforeCreatingAnything() throws {
        let (source, output, parent) = try setup("immutable")
        for flag in [UF_IMMUTABLE, UF_APPEND] {
            XCTAssertEqual(chflags(source.path, UInt32(flag)), 0)
            defer { _ = chflags(source.path, 0) }
            XCTAssertThrowsError(try ArchiveUpdater.open(url: source, output: output)) {
                XCTAssertEqual($0 as? WriterError, .io(operation: "source flags", code: EPERM))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            XCTAssertEqual(chflags(source.path, 0), 0)
        }
    }

    func testOnlyENOTSUPAndEXDEVFallBackAndStillMatchBytes() throws {
        let (source, output, parent) = try setup("fallback")
        for code in [EACCES, EIO, EPERM, ENOSPC] {
            try ArchiveSourceSnapshot.$testingCloneError.withValue(code) {
                XCTAssertThrowsError(try ArchiveUpdater.open(url: source, output: output)) {
                    XCTAssertEqual($0 as? WriterError, .io(operation: "clone source", code: code))
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
        for code in [ENOTSUP, EXDEV] {
            try ArchiveSourceSnapshot.$testingCloneError.withValue(code) {
                let updater = try ArchiveUpdater.open(url: source, output: output)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
                try updater.remove(entriesAt: [0]); try updater.commit()
            }
            let oracle = parent.appendingPathComponent("oracle.zip")
            try ZipP1Support.legacy(source: source, output: oracle, operations: [.remove([0])])
            try ZipP1Support.assertEqualFiles(output, oracle)
            try FileManager.default.removeItem(at: output); try FileManager.default.removeItem(at: oracle)
        }
    }

    func testSourceChangeInvalidPathsAbandonmentAndReplacementInodes() throws {
        let (source, output, parent) = try setup("cleanup")
        try Data([1]).write(to: output)
        XCTAssertThrowsError(try ArchiveUpdater.open(url: source, output: output)) {
            guard case WriterError.invalidPath = $0 else { return XCTFail("\($0)") }
        }
        try FileManager.default.removeItem(at: output)
        XCTAssertThrowsError(try ArchiveUpdater.open(url: source, output: parent.appendingPathComponent("missing/out.zip"))) {
            guard case WriterError.invalidPath = $0 else { return XCTFail("\($0)") }
        }
        do {
            let updater = try ArchiveUpdater.open(url: source, output: output)
            try updater.add(data: Data([1]), as: "added")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        do {
            let updater = try ArchiveUpdater.open(url: source, output: output)
            try updater.add(data: Data([1]), as: "added")
            let snapshots = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).filter { $0 != output }
            for path in snapshots + [output] {
                try FileManager.default.removeItem(at: path)
                try Data([0x42]).write(to: path)
            }
            XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
            for path in snapshots + [output] { XCTAssertEqual(try Data(contentsOf: path), Data([0x42])); try FileManager.default.removeItem(at: path) }
        }
        do {
            let updater = try ArchiveUpdater.open(url: source, output: output)
            let handle = try FileHandle(forWritingTo: source)
            try handle.seek(toOffset: 31); try handle.write(contentsOf: Data([99])); try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: source.path)
            XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testUnchangedEmptyAndEmptyAppendMatchReplace() throws {
        let (source, output, parent) = try setup("empty")
        for empty in [false, true] {
            let input: URL
            if empty {
                input = source.deletingLastPathComponent().appendingPathComponent("empty.zip")
                try ArchiveWriter.create(url: input).finish()
            } else { input = source }
            for append in [false, true] {
                let replacement = parent.appendingPathComponent("replace.zip")
                try FileManager.default.copyItem(at: input, to: replacement)
                let a = try ArchiveUpdater.open(url: input, output: output), b = try ArchiveUpdater.open(url: replacement)
                if append {
                    for updater in [a, b] { try updater.add(data: Data([1]), as: "added", modificationDate: ZipTestSupport.date) }
                }
                try a.commit(); try b.commit()
                try ZipP1Support.assertEqualFiles(output, replacement)
                XCTAssertEqual(a.lastCommitStrategy, append ? .appendOnly : .unchanged)
                try FileManager.default.removeItem(at: output); try FileManager.default.removeItem(at: replacement)
            }
        }
    }
}
