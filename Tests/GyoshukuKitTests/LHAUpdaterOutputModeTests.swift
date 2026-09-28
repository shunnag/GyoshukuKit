import Foundation
import Darwin
import KaitoKit
import XCTest
import Synchronization
@_spi(Testing) @testable import GyoshukuKit

final class LHAUpdaterOutputModeTests: XCTestCase {
    func testHostVolume() throws { try lifecycle(at: TestSupport.directory("lha-host"), permissions: true) }
    func testFAT32() throws { let disk = try ArchiveTestDisk("MS-DOS FAT32"); try lifecycle(at: disk.mount, permissions: false) }
    func testExFAT() throws { let disk = try ArchiveTestDisk("ExFAT"); try lifecycle(at: disk.mount, permissions: false) }
    func testHFSPlus() throws { let disk = try ArchiveTestDisk("HFS+"); try lifecycle(at: disk.mount, permissions: true) }

    private func lifecycle(at root: URL, permissions: Bool) throws {
        for sequential in [false, true] {
            for action in ["unchanged", "first", "last", "same", "long", "add", "relocate", "discard", "cancel", "fault", "foreign"] {
                let work = try TestSupport.work(in: root), source = try LHAUpdateSupport.generated(work)
                let output = work.appendingPathComponent("out.lzh"), saved = work.appendingPathComponent("saved")
                let before = try Data(contentsOf: source), info = try ZipP1Support.info(source)
                let context = "\(root.path) sequential=\(sequential) action=\(action)"
                try LHAUpdater.$testingDisablesClone.withValue(sequential) {
                    var updater: LHAUpdater? = try LHAUpdater.open(url: source, output: output)
                    if ["add", "relocate", "discard", "foreign"].contains(action) { try updater!.add(data: Data([7]), as: "added") }
                    if action == "first" || action == "relocate" { try updater!.remove(entriesAt: [0]) }
                    if action == "last" || action == "fault" { try updater!.remove(entriesAt: [5]) }
                    if action == "same" || action == "long" { try updater!.rename(entryAt: 2, to: action == "same" ? "edit-000002" : "longer-name-than-before") }
                    if action == "foreign" {
                        try FileManager.default.moveItem(at: output, to: saved)
                        try Data([99]).write(to: output)
                    } else if action == "cancel" {
                        var fired = false
                        XCTAssertThrowsError(try updater!.commit { _ in fired = true; throw CancellationError() }, context) { XCTAssertTrue($0 is CancellationError, "\($0) \(context)") }
                        XCTAssertTrue(fired, context)
                    } else if action == "fault" {
                        try LHAUpdater.$testingFault.withValue(.dropTerminator) {
                            XCTAssertThrowsError(try updater!.commit(), context) { guard case UpdaterRouteError.outputVerificationFailed = $0 else { return XCTFail("\($0) \(context)") } }
                        }
                    } else if action != "discard" {
                        try updater!.commit()
                        if action == "unchanged" { XCTAssertEqual(try Data(contentsOf: output), before, context) }
                        if permissions { XCTAssertEqual(try ZipP1Support.info(output).st_mode & 0o777, 0o600, context) }
                        let outputInfo = try ZipP1Support.info(output)
                        for fd: Int32 in 0..<256 {
                            var open = stat()
                            if fstat(fd, &open) == 0 { XCTAssertFalse(open.st_dev == outputInfo.st_dev && open.st_ino == outputInfo.st_ino, "open output fd \(fd) \(context)") }
                        }
                        let reader = try ArchiveReader.open(url: output)
                        for entry in reader.entries { _ = try reader.read(entry) }
                    }
                    updater = nil
                }
                if action == "foreign" { XCTAssertEqual(try Data(contentsOf: output), Data([99]), context); try FileManager.default.removeItem(at: saved) }
                XCTAssertEqual(try Data(contentsOf: source), before, context)
                let after = try ZipP1Support.info(source)
                XCTAssertEqual(after.st_ino, info.st_ino, context)
                XCTAssertEqual(after.st_mtimespec.tv_sec, info.st_mtimespec.tv_sec, context)
                XCTAssertEqual(after.st_mtimespec.tv_nsec, info.st_mtimespec.tv_nsec, context)
                let failed = ["discard", "cancel", "fault"].contains(action)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(), failed ? ["source.lzh"] : ["out.lzh", "source.lzh"], context)
            }
        }
    }
    func testSourceChangesFlagsAndCloneErrors() throws {
        let root = try TestSupport.directory("lha-source-state"), source = try LHAUpdateSupport.generated(root)
        for code in [EIO, EPERM, EXDEV, ENOTSUP] {
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
            try ArchiveSourceSnapshot.$testingCloneError.withValue(code) {
                if code == EXDEV || code == ENOTSUP {
                    let editor = try LHAUpdater.open(url: source, output: output)
                    try editor.remove(entriesAt: [0]); try editor.commit()
                    XCTAssertEqual(editor.lastCommitStrategy, .sequential)
                } else {
                    XCTAssertThrowsError(try LHAUpdater.open(url: source, output: output)) { XCTAssertEqual($0 as? WriterError, .io(operation: "clone source", code: code)) }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
                }
            }
        }
        let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        XCTAssertThrowsError(try LHAUpdater.open(url: source, output: output)) { XCTAssertEqual($0 as? WriterError, .io(operation: "source flags", code: EPERM)) }
        _ = chflags(source.path, 0)
        let editor = try LHAUpdater.open(url: source, output: output)
        try editor.addDirectory("added")
        let file = try FileHandle(forWritingTo: source)
        try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
        XCTAssertThrowsError(try editor.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
    func testReservationsOwnersEncoderFailureAndDescriptorDuplication() throws {
        let root = try TestSupport.directory("lha-reservations"), source = try LHAUpdateSupport.generated(root)
        let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
        let editor = try LHAUpdater.open(url: source, output: output)
        XCTAssertThrowsError(try editor.addDirectory("new", modificationDate: nil, ownerIDs: .init(user: 501, group: 20))) { XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try editor.add(data: Data(), as: "new")
        XCTAssertThrowsError(try editor.rename(entryAt: 0, to: "new"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        let bad = try LHAUpdater.open(url: source, output: output, options: .init(compressionThreads: 2), encoder: { _ in throw WriterError.invalidState })
        XCTAssertThrowsError(try { try bad.add(data: Data(count: 1 << 20), as: "added"); try bad.commit() }())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        let fd = Darwin.open(source.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let duplicate = try ZipUpdateSource(duplicating: fd)
        XCTAssertEqual(close(fd), 0)
        let reads = ZipIOEvents()
        XCTAssertEqual(try ZipUpdateSource.$readObserver.withValue(reads.read) { try duplicate.bytes(at: 0, count: 7) }, try Data(contentsOf: source).prefix(7))
        XCTAssertTrue(reads.events.allSatisfy { $0.descriptor == duplicate.descriptor && $0.descriptor != fd })
    }
    func testProgressThrowAndReentrancyInvalidateCommit() throws {
        for action in 0..<6 {
            let root = try TestSupport.directory("lha-reentrant-\(action)"), source = try LHAUpdateSupport.generated(root)
            let work = try TestSupport.work(in: root)
            let editor = try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))
            try editor.addDirectory("added")
            XCTAssertThrowsError(try editor.commit { update in
                if action == 5 && update.completedBytes == 0 { return }
                switch action {
                case 0, 5: throw CancellationError()
                case 1: try editor.addDirectory("nested")
                case 2: try editor.remove(entriesAt: [0])
                case 3: try editor.rename(entryAt: 0, to: "nested")
                default: try editor.commit()
                }
            }) { if action == 0 || action == 5 { XCTAssertTrue($0 is CancellationError) } else { XCTAssertEqual($0 as? UpdaterError, .invalidState) } }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
    func testCancellationDuringCopyAndV3Decode() async throws {
        for sequential in [false, true] {
            for decode in [false, true] {
                let root = try TestSupport.directory("lha-cancel-\(sequential)-\(decode)"), source = try LHAUpdateSupport.generated(root)
                let work = try TestSupport.work(in: root), fired = Mutex(false)
                let task = Task {
                    try LHAUpdater.$testingDisablesClone.withValue(sequential) {
                        let editor = try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))
                        if decode { try editor.add(data: LHATestSupport.random(3 << 20), as: "large") }
                        else { try editor.remove(entriesAt: [0]) }
                        if decode {
                            // V3 uses a dup descriptor; V5 and V2 use direct pread and don't report here.
                            try ZipUpdateSource.$readObserver.withValue({ _, offset, _ in
                                if offset > 10000 { fired.withLock { $0 = true }; withUnsafeCurrentTask { $0?.cancel() } }
                            }) { try editor.commit() }
                        } else {
                            try ZipCopyEngine.$writeObserver.withValue({ _, _ in fired.withLock { $0 = true }; withUnsafeCurrentTask { $0?.cancel() } }) { try editor.commit() }
                        }
                    }
                }
                do { try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                XCTAssertTrue(fired.withLock { $0 })
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
            }
        }
    }
}
