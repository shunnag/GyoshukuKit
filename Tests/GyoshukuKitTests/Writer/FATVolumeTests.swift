import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class FATVolumeTests: XCTestCase {
    func testFAT32() async throws { try await onDisk("MS-DOS FAT32") }
    func testExFAT() async throws { try await onDisk("ExFAT") }
    func testHFSPlus() async throws { try await onDisk("HFS+", clusterInodes: false) }

    func testHostVolume() async throws {
        let root = try TestSupport.directory("fat-regressions-host")
        defer { try? FileManager.default.removeItem(at: root) }
        try await exercise(root, clusterInodes: false)
    }

    private func onDisk(_ fileSystem: String, clusterInodes: Bool = true) async throws {
        let disk = try ArchiveTestDisk(fileSystem)
        try ownership(disk.mount, clusterInodes: clusterInodes, checkDirectoryContents: false)
        let root = disk.mount.appendingPathComponent("cases")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try await exercise(root, clusterInodes: clusterInodes)
        try disk.detach()
    }

    private func exercise(_ root: URL, clusterInodes: Bool) async throws {
        let nested = try directory(root, "ownership")
        try ownership(nested, clusterInodes: clusterInodes)
        try ownership(try directory(nested, "deeper"), clusterInodes: clusterInodes)
        try tarCommits(root)
        try await tarFailures(root)
        try splicedOutput(root)
        try writersAndRewriters(root)
        try zipUpdater(root)
    }

    private func directory(_ parent: URL, _ label: String) throws -> URL {
        let url = parent.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func contents(_ root: URL, _ expected: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), expected, file: file, line: line)
    }

    private func ownership(_ work: URL, clusterInodes: Bool, checkDirectoryContents: Bool = true) throws {
        let path = work.appendingPathComponent("file")
        let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let empty = try ZipEditTestSupport.info(path)
        if clusterInodes {
            XCTAssertGreaterThanOrEqual(empty.st_ino, ino_t(1) << 63)
            XCTAssertFalse(ArchiveOwnedFile.hasAssignedInode(empty.st_ino))
        }
        XCTAssertTrue(ArchiveOwnedFile.matches(url: path, descriptor: fd))
        try handle.write(contentsOf: Data(repeating: 1, count: 4096))
        let filled = try ZipEditTestSupport.info(path)
        XCTAssertTrue(ArchiveOwnedFile.hasAssignedInode(filled.st_ino))
        if clusterInodes { XCTAssertNotEqual(empty.st_ino, filled.st_ino) }
        let recorded = try ArchiveOwnedFile(url: path, descriptor: fd)
        XCTAssertTrue(ArchiveOwnedFile.matches(url: path, descriptor: fd))
        try handle.truncate(atOffset: 0)
        if clusterInodes {
            let truncated = try ZipEditTestSupport.info(path)
            XCTAssertGreaterThanOrEqual(truncated.st_ino, ino_t(1) << 63)
            XCTAssertFalse(ArchiveOwnedFile.hasAssignedInode(truncated.st_ino))
            recorded.remove()
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
        XCTAssertTrue(ArchiveOwnedFile.matches(url: path, descriptor: fd))
        let moved = work.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: path, to: moved)
        try Data().write(to: path)
        if clusterInodes {
            let replacement = try ZipEditTestSupport.info(path)
            XCTAssertGreaterThanOrEqual(replacement.st_ino, ino_t(1) << 63)
            XCTAssertFalse(ArchiveOwnedFile.hasAssignedInode(replacement.st_ino))
        }
        XCTAssertFalse(ArchiveOwnedFile.matches(url: path, descriptor: fd))
        ArchiveOwnedFile.remove(url: path, descriptor: fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        // volume root には Spotlight 等の管理 file が増える場合がある。
        if checkDirectoryContents { try contents(work, ["file", "moved"]) }
        ArchiveOwnedFile.remove(url: moved, descriptor: fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        if checkDirectoryContents { try contents(work, ["file"]) }
        try FileManager.default.removeItem(at: path)
    }

    private func tarCommits(_ root: URL) throws {
        for operation in ["delete-first", "delete-last", "rename-same", "rename-different", "add", "relocate", "unchanged", "delete-all"] {
            let work = try directory(root, operation), source = try TarEditTestSupport.fixture(work, size: 65536)
            let original = try Data(contentsOf: source), identity = try ZipEditTestSupport.info(source)
            let output = work.appendingPathComponent("archive.tar")
            var names = (0..<6).map { String(format: "file-%06d", $0) }
            var bodies = (0..<6).map { Data(repeating: UInt8($0), count: 65536) }
            try TarUpdater.$testingDisablesClone.withValue(true) {
                let editor = try TarUpdater.open(url: source, output: output)
                switch operation {
                case "delete-first": try editor.remove(entriesAt: [0]); names.removeFirst(); bodies.removeFirst()
                case "delete-last": try editor.remove(entriesAt: [5]); names.removeLast(); bodies.removeLast()
                case "rename-same", "rename-different":
                    names[2] = operation == "rename-same" ? "edit-000002" : String(repeating: "n", count: 150)
                    try editor.rename(entryAt: 2, to: names[2])
                case "add", "relocate":
                    try editor.add(data: Data([7, 8]), as: "added")
                    names.append("added"); bodies.append(Data([7, 8]))
                    if operation == "relocate" { try editor.remove(entriesAt: [0]); names.removeFirst(); bodies.removeFirst() }
                case "delete-all": try editor.remove(entriesAt: Array(0..<6)); names = []; bodies = []
                default: break
                }
                try editor.commit()
                XCTAssertEqual(editor.lastCommitStrategy, operation == "relocate" ? .relocatedAppend : operation == "unchanged" ? .unchanged : .sequential)
            }
            try verifyArchive(output, names: names, bodies: bodies)
            try unchanged(source, original, identity)
            if operation == "unchanged" { XCTAssertEqual(try Data(contentsOf: output), original) }
            try contents(work, ["source.tar", "archive.tar"])
        }
    }

    private func unchanged(_ source: URL, _ bytes: Data, _ identity: stat) throws {
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let after = try ZipEditTestSupport.info(source)
        XCTAssertEqual(after.st_ino, identity.st_ino)
        XCTAssertEqual(after.st_mtimespec.tv_sec, identity.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, identity.st_mtimespec.tv_nsec)
    }

    private func verifyArchive(_ output: URL, names: [String], bodies: [Data], password: String? = nil) throws {
        let reader = try ArchiveReader.open(url: output, options: .init(password: password))
        XCTAssertEqual(reader.entries.map(\.name), names)
        for (entry, body) in zip(reader.entries, bodies) { XCTAssertEqual(try reader.read(entry), body) }
    }

    private func tarFailures(_ root: URL) async throws {
        for action in ["cancel", "discard", "fault", "final-progress"] {
            let work = try directory(root, action), source = try TarEditTestSupport.fixture(work, size: 65536)
            let original = try Data(contentsOf: source), identity = try ZipEditTestSupport.info(source)
            let output = work.appendingPathComponent("archive.tar")
            if action == "cancel" {
                let task = Task {
                    try TarUpdater.$testingDisablesClone.withValue(true) {
                        let editor = try TarUpdater.open(url: source, output: output)
                        try editor.remove(entriesAt: [0])
                        try ZipCopyEngine.$testingBufferSize.withValue(16384) {
                            try ZipCopyEngine.$writeObserver.withValue({ _, _ in withUnsafeCurrentTask { $0?.cancel() } }) {
                                try editor.commit()
                            }
                        }
                    }
                }
                do { try await task.value; XCTFail("expected cancellation") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            } else {
                try TarUpdater.$testingDisablesClone.withValue(true) {
                    var editor: TarUpdater? = try TarUpdater.open(url: source, output: output)
                    if action == "discard" {
                        try editor!.add(data: Data([7]), as: "added")
                        editor = nil
                    } else {
                        try editor!.remove(entriesAt: [0])
                        if action == "fault" {
                            try TarUpdater.$testingFault.withValue(.flipWrittenByte(1024)) {
                                XCTAssertThrowsError(try editor!.commit()) {
                                    guard case TarUpdaterError.outputVerificationFailed = $0 else { return XCTFail("\($0)") }
                                }
                            }
                        } else {
                            XCTAssertThrowsError(try editor!.commit { update in
                                if update.completedBytes == update.totalBytes { throw CancellationError() }
                            }) { XCTAssertTrue($0 is CancellationError) }
                        }
                    }
                }
            }
            try unchanged(source, original, identity)
            try contents(work, ["source.tar"])
        }
    }

    private func splicedOutput(_ root: URL) throws {
        for action in ["commit", "relocate", "discard", "empty-discard", "scratch-discard", "scratch-failure", "foreign-empty", "foreign-scratch", "foreign-empty-scratch"] {
            let work = try directory(root, "spliced-" + action), source = work.appendingPathComponent("source.bin")
            let bytes = Data((0..<100).map(UInt8.init))
            try bytes.write(to: source)
            let path = work.appendingPathComponent("output.bin")
            let snapshot = try ArchiveSourceSnapshot(url: source, directory: work, pathExtension: "bin", disablesClone: true)
            let output = SplicedArchiveOutput(snapshot: snapshot, output: path, pathExtension: "bin", sequential: true)
            let scratch = try output.makeScratch(tag: "volume")
            XCTAssertEqual(try scratch.source().length, 0)
            try scratch.append(Data([201, 202]))
            XCTAssertEqual(try scratch.source().bytes(at: 0, count: 2), Data([201, 202]))
            _ = try output.makeScratch(tag: "empty")
            if action == "foreign-scratch" || action == "foreign-empty-scratch" {
                let prefix = action == "foreign-scratch" ? ".gyoshuku-volume-" : ".gyoshuku-empty-"
                let replaced = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(prefix) })
                let moved = work.appendingPathComponent("moved.bin")
                try FileManager.default.moveItem(at: replaced, to: moved)
                let foreign = action == "foreign-scratch" ? Data([77]) : Data()
                try foreign.write(to: replaced)
                XCTAssertEqual(try scratch.source().bytes(at: 0, count: 2), Data([201, 202]))
                output.discard()
                XCTAssertEqual(try Data(contentsOf: replaced), foreign)
                try contents(work, ["source.bin", "moved.bin", replaced.lastPathComponent])
                continue
            }
            let offset: UInt64 = action == "empty-discard" || action == "foreign-empty" ? 0 : 50
            let handle = try output.beginAppend(at: offset, prefix: offset == 0 ? [] : [.source(0..<50)])
            if action == "foreign-empty" {
                let moved = work.appendingPathComponent("moved.bin")
                try FileManager.default.moveItem(at: path, to: moved)
                try Data().write(to: path)
                output.discard()
                try handle.close()
                try contents(work, ["source.bin", "output.bin", "moved.bin"])
                continue
            }
            if action == "empty-discard" { try handle.close(); output.discard() }
            else {
                try handle.write(contentsOf: Data([101, 102]))
                try handle.close()
                if action == "discard" || action == "scratch-discard" { output.discard() }
                else {
                    let prefix: [SplicedSegment]
                    if action == "scratch-failure" { prefix = [.generated(length: 1, write: { try $0.write(Data([1, 2])) })] }
                    else if action == "relocate" { prefix = [.source(10..<40)] }
                    else { prefix = [.generated(length: 2, write: { try $0.copy(0..<2, from: scratch.source()) })] }
                    let length: UInt64 = action == "scratch-failure" ? 1 : action == "relocate" ? 30 : 2
                    let plan = SplicedCommitPlan(prefix: prefix, appended: 50..<52, terminal: Data([255]),
                        finalLength: length + 3, formatVerificationUnits: 0)
                    let meter = CommitProgressMeter(total: output.units(for: plan), progress: nil)
                    if action == "scratch-failure" {
                        XCTAssertThrowsError(try output.commit(plan, meter: meter) { _, _ in }) {
                            guard case TarUpdaterError.outputVerificationFailed = $0 else { return XCTFail("\($0)") }
                        }
                    } else {
                        XCTAssertEqual(try output.commit(plan, meter: meter) { _, _ in }, .relocatedAppend)
                        let expected = action == "relocate" ? Data((10..<40).map(UInt8.init)) : Data([201, 202])
                        XCTAssertEqual(try Data(contentsOf: path), expected + Data([101, 102, 255]))
                    }
                }
            }
            try contents(work, action == "commit" || action == "relocate" ? ["source.bin", "output.bin"] : ["source.bin"])
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    private func writersAndRewriters(_ root: URL) throws {
        for format in [GyoshukuKit.ArchiveFormat.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha] {
            let work = try directory(root, "writer-" + format.testFileExtension)
            let disk = work.appendingPathComponent("empty")
            try Data().write(to: disk)
            let output = work.appendingPathComponent("out." + format.testFileExtension)
            let writer = try ArchiveWriter.create(url: output, format: format)
            try writer.add(contentsOf: disk, as: "empty")
            try writer.finish()
            try verifyArchive(output, names: ["empty"], bodies: [Data()])
            try FileManager.default.removeItem(at: output)
            if format != .zip {
                var abandoned: ArchiveWriter? = try ArchiveWriter.create(url: output, format: format)
                try abandoned!.add(data: Data([1]), as: "body")
                abandoned = nil
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            let source = try TarEditTestSupport.fixture(work, count: 2)
            for placement in [AdditionPlacement.beginning, .end] {
                let editor = try ArchiveRewriter.open(url: source, output: output, format: format,
                                                     options: .init(additionPlacement: placement))
                try editor.add(data: Data([7]), as: "new")
                XCTAssertThrowsError(try editor.commit { _, _ in throw CancellationError() }) { XCTAssertTrue($0 is CancellationError) }
                try contents(work, ["empty", "source.tar"])
            }
            var discarded: ArchiveRewriter? = try ArchiveRewriter.open(url: source, output: output, format: format,
                                                                       options: .init(additionPlacement: .beginning))
            try discarded!.add(data: Data([8]), as: "new")
            discarded = nil
            try contents(work, ["empty", "source.tar"])
        }
    }

    private func zipUpdater(_ root: URL) throws {
        let work = try directory(root, "zip-updater")
        let source = try ReencryptionSupport.fixture(work, items: [("old", Data([1, 2])), ("keep", Data([3, 4]))])
        let original = try Data(contentsOf: source), identity = try ZipEditTestSupport.info(source)
        let output = work.appendingPathComponent("output.zip")
        let updater = try ArchiveUpdater.open(url: source, output: output)
        try updater.add(data: Data([5]), as: "added")
        try updater.remove(entriesAt: [0])
        try updater.commit()
        try verifyArchive(output, names: ["keep", "added"], bodies: [Data([3, 4]), Data([5])])
        try FileManager.default.removeItem(at: output)
        _ = try ReencryptionSupport.convert(source, to: output, current: nil, password: "new")
        try verifyArchive(output, names: ["old", "keep"], bodies: [Data([1, 2]), Data([3, 4])], password: "new")
        try FileManager.default.removeItem(at: output)
        let failed = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "new"))
        try failed.reencryptExistingEntries(currentPassword: nil)
        failed.testingAfterRebuild = { _ in throw CancellationError() }
        XCTAssertThrowsError(try failed.commit()) { XCTAssertTrue($0 is CancellationError) }
        try unchanged(source, original, identity)
        try contents(work, ["source.zip"])
    }
}
