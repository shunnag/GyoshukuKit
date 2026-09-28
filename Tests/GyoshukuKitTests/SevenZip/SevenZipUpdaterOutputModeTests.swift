import Foundation
import Darwin
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterOutputModeTests: XCTestCase {
    func testHostLifecycle() throws { try lifecycle(TestSupport.directory("7z-lifecycle-host")) }
    func testFAT32() throws { let disk = try ArchiveTestDisk("MS-DOS FAT32"); try lifecycle(disk.mount, permissions: false) }
    func testExFAT() throws { let disk = try ArchiveTestDisk("ExFAT"); try lifecycle(disk.mount, permissions: false) }
    func testHFSPlus() throws { let disk = try ArchiveTestDisk("HFS+"); try lifecycle(disk.mount) }

    private func lifecycle(_ root: URL, permissions: Bool = true) throws {
        let source = try SevenZipEditSupport.source(root)
        let before = try Data(contentsOf: source), originalInfo = try ZipEditTestSupport.info(source)
        for sequential in [false, true] {
            for operation in ["first", "last", "same", "long", "add", "relocate", "unchanged", "cancel", "discard", "fault"] {
                let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
                var updater: SevenZipUpdater? = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                    try SevenZipUpdater.open(url: source, output: output)
                }
                switch operation {
                case "first", "fault": try updater!.remove(entriesAt: [0])
                case "last": try updater!.remove(entriesAt: [3])
                case "same": try updater!.rename(entryAt: 0, to: "other")
                case "long": try updater!.rename(entryAt: 0, to: "different-length-日本語")
                case "add", "relocate", "discard":
                    try updater!.add(data: Data([1, 2, 3]), as: "new", modificationDate: TestSupport.date)
                    if operation == "relocate" { try updater!.remove(entriesAt: [0]) }
                default: break
                }
                if operation == "discard" { updater = nil }
                else if operation == "fault" {
                    XCTAssertThrowsError(try SevenZipUpdater.$testingFault.withValue(.flipMovedPackByte) { try updater!.commit() }, operation)
                } else if operation == "cancel" {
                    var fired = false
                    XCTAssertThrowsError(try updater!.commit { _ in fired = true; throw CancellationError() }, operation) { XCTAssertTrue($0 is CancellationError) }
                    XCTAssertTrue(fired, operation)
                } else {
                    try updater!.commit()
                    let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
                    if permissions { XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, operation) }
                    let info = try ZipEditTestSupport.info(output)
                    for fd: Int32 in 0..<256 {
                        var opened = stat()
                        if fstat(fd, &opened) == 0 { XCTAssertFalse(opened.st_dev == info.st_dev && opened.st_ino == info.st_ino, "open output fd \(fd), \(operation)") }
                    }
                    _ = try SevenZipEditSupport.items(SevenZipEditSupport.reader(output))
                    if operation == "unchanged" { XCTAssertEqual(try Data(contentsOf: output), before) }
                }
                XCTAssertEqual(try Data(contentsOf: source), before, operation)
                let after = try ZipEditTestSupport.info(source)
                XCTAssertEqual(after.st_ino, originalInfo.st_ino, operation)
                XCTAssertEqual(after.st_mtimespec.tv_sec, originalInfo.st_mtimespec.tv_sec, operation)
                XCTAssertEqual(after.st_mtimespec.tv_nsec, originalInfo.st_mtimespec.tv_nsec, operation)
                let files = try FileManager.default.contentsOfDirectory(atPath: work.path)
                XCTAssertEqual(files, ["cancel", "discard", "fault"].contains(operation) ? [] : ["output.7z"], operation)
            }
        }
    }

    func testSourceChangeReentryAndForeignOutputAreSafe() throws {
        let root = try TestSupport.directory("7z-source-lifecycle")
        for mode in ["source", "reentry", "foreign", "throw"] {
            let work = try TestSupport.work(in: root)
            let source = try SevenZipEditSupport.source(work)
            let output = work.appendingPathComponent("output.7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            try updater.add(data: Data([1]), as: "added")
            if mode == "source" {
                let file = try FileHandle(forWritingTo: source); try file.seekToEnd(); try file.write(contentsOf: Data([1])); try file.close()
            }
            if mode == "foreign" {
                try FileManager.default.removeItem(at: output)
                try Data([99]).write(to: output)
            }
            XCTAssertThrowsError(try updater.commit { _ in
                if mode == "reentry" { try? updater.remove(entriesAt: [0]) }
                if mode == "throw" { throw CocoaError(.userCancelled) }
            })
            if mode == "foreign" { XCTAssertEqual(try Data(contentsOf: output), Data([99])) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".gyoshuku-") })
            XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
        }
    }

    func testCloneWritesOnlyChangedBytes() throws {
        let root = try TestSupport.directory("7z-write-counts")
        let source = try SevenZipEditSupport.source(root, count: 1002)
        let original = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(source)))
        for operation in ["rename", "last", "add", "first", "middle"] {
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            guard updater.destination.isCloneMode else { throw XCTSkip("clone unavailable") }
            let events = ZipIOEvents()
            let reads = ZipIOEvents()
            let verification = ZipIOEvents()
            try ZipUpdateSource.$readObserver.withValue(reads.read) {
            try ZipCopyEngine.$writeObserver.withValue(events.write) {
            try SplicedArchiveOutput.$verificationReadObserver.withValue(verification.write) {
                switch operation {
                case "rename": try updater.rename(entryAt: 1, to: "renamed")
                case "last": try updater.remove(entriesAt: [1001])
                case "first": try updater.remove(entriesAt: [0])
                case "middle": try updater.remove(entriesAt: [500])
                default: try updater.add(data: Data([1, 2, 3]), as: "added", modificationDate: TestSupport.date)
                }
                try updater.commit()
            }
            }
            }
            let stats = try XCTUnwrap(updater.lastCommitStatistics)
            XCTAssertEqual(events.bytes, stats.storedHeaderBytes + 64 + stats.appendedPackBytes + stats.writtenCarriedPackBytes, operation)
            let moved = ["first", "middle"].contains(operation)
                ? original.packs.dropFirst(operation == "first" ? 1 : 501).reduce(UInt64(0)) { $0 + $1.length } : 0
            XCTAssertEqual(stats.writtenCarriedPackBytes, moved, operation)
            XCTAssertEqual(reads.events.filter { $0.descriptor == updater.snapshot.source.descriptor }.reduce(UInt64(0)) { $0 + UInt64($1.count) }, moved, operation)
            XCTAssertEqual(verification.bytes, moved * 2, operation)
            XCTAssertFalse(reads.events.contains { $0.descriptor == updater.snapshot.original.descriptor }, operation)
        }
    }

    func testSourceFlagsAndCloneErrors() throws {
        let root = try TestSupport.directory("7z-source-flags"), source = try SevenZipEditSupport.source(root)
        for code in [EIO, EPERM, EXDEV, ENOTSUP] {
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
            try ArchiveSourceSnapshot.$testingCloneError.withValue(code) {
                if code == EXDEV || code == ENOTSUP {
                    let updater = try SevenZipUpdater.open(url: source, output: output)
                    try updater.remove(entriesAt: [0]); try updater.commit()
                    XCTAssertEqual(updater.lastCommitStrategy, .sequential)
                } else {
                    XCTAssertThrowsError(try SevenZipUpdater.open(url: source, output: output)) {
                        XCTAssertEqual($0 as? WriterError, .io(operation: "clone source", code: code))
                    }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
                }
            }
        }
        let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        XCTAssertThrowsError(try SevenZipUpdater.open(url: source, output: output)) {
            XCTAssertEqual($0 as? WriterError, .io(operation: "source flags", code: EPERM))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testTenThousandDirectoriesAndLongerNameProgress() throws {
        let root = try TestSupport.directory("7z-directory-progress"), source = root.appendingPathComponent("source.7z")
        let writer = try ArchiveWriter.create(url: source, format: .sevenZip)
        for index in 0..<10000 { try writer.addDirectory("dir-\(index)", modificationDate: TestSupport.date, ownerIDs: nil) }
        try writer.finish()
        let updater = try SevenZipUpdater.open(url: source, output: root.appendingPathComponent("output.7z"))
        try updater.rename(entryAt: 9999, to: String(repeating: "長", count: 150))
        var updates: [ArchiveUpdater.CommitProgress] = []
        try updater.commit { updates.append($0) }
        XCTAssertEqual(updates.map(\.completedBytes), updates.map(\.completedBytes).sorted())
        XCTAssertTrue(updates.allSatisfy { $0.totalBytes == updates.first!.totalBytes && $0.completedBytes <= $0.totalBytes })
        XCTAssertEqual(updates.last?.completedBytes, updates.last?.totalBytes)
        let stats = try XCTUnwrap(updater.lastCommitStatistics)
        XCTAssertEqual(updates.last?.totalBytes, 64 + stats.plainHeaderBytes * 2)
    }
}
