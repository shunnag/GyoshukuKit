import Foundation
import Darwin
import Synchronization
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarLifecycleTests: XCTestCase {
    func testUnchangedCopyStageWithoutChunkMap() throws {
        for format in [GyoshukuKit.ArchiveFormat.tarGzip, .tarXZ] {
            let root = try TestSupport.directory("compressed-tar-mapless-cancellation-\(format)")
            let source = try CompressedTarTestSupport.fixture(root, format, large: false)
            try FileManager.default.removeItem(at: root.appendingPathComponent("input.tar"))
            let reason: ChunkMapUnavailableReason
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            if format == .tarGzip {
                // A second, empty gzip member keeps the tar image intact but disables K1's map.
                let empty = try GzipCompressor(level: 6, threads: 1)
                try empty.write(Data(), finish: true) { try handle.write(contentsOf: $0) }
                reason = .multipleGzipMembers
            } else {
                try handle.write(contentsOf: Data(count: 4))
                reason = .xzStreamPadding
            }
            try handle.close()
            let original = try Data(contentsOf: source)
            for cancel in [false, true] {
                let output = root.appendingPathComponent("output")
                let reader = try CompressedTarTestSupport.open(source)
                let base = try XCTUnwrap(reader.tarEditingSnapshot())
                let context = "\(format), cancel=\(cancel), chunkMapUnavailableReason=\(String(describing: base.chunkMapUnavailableReason))"
                XCTAssertNil(base.chunkMap, context)
                XCTAssertEqual(base.chunkMapUnavailableReason, reason, context)
                let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
                let calls = Mutex(0), writes = IOEvents()
                do {
                    let result = try CompressedTarUpdater.$testingStage.withValue({ stage in
                        if stage == .copying {
                            calls.withLock { $0 += 1 }
                            if cancel { throw CancellationError() }
                        }
                    }) {
                        try ZipCopyEngine.$writeObserver.withValue(writes.write) { try editor.commit(progress: nil) }
                    }
                    if cancel { XCTFail("\(context): cancellation committed") }
                    else {
                        XCTAssertEqual(result.strategy, .unchanged, context)
                        XCTAssertEqual(try Data(contentsOf: output), original, context)
                        let verified = try CompressedTarTestSupport.verify(output, base: base, result: result)
                        try XCTAssertByteSourcesEqual(verified.tarEditingSnapshot()!.image, base.image)
                        try FileManager.default.removeItem(at: output)
                    }
                } catch {
                    XCTAssertTrue(cancel && error is CancellationError, "\(context): \(error)")
                }
                XCTAssertEqual(calls.withLock { $0 }, 1, context)
                if cancel { XCTAssertEqual(writes.bytes, 0, "\(context): copying started before cancellation") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), context)
                XCTAssertEqual(try Data(contentsOf: source), original, context)
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [source.lastPathComponent], context)
            }
        }
    }

    func testCancellationAndProgressFailureRemoveOnlyOwnedOutput() throws {
        enum Stop: Error { case requested }
        let root = try TestSupport.directory("compressed-tar-cancellation")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip)
        let original = try Data(contentsOf: source)
        for stage in [CompressedTarUpdater.Stage.planned, .encoding, .copying, .selfCheck] {
            let output = root.appendingPathComponent("cancel-\(stage)")
            let editor = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
            try editor.add(data: Data([7]), as: "added")
            XCTAssertThrowsError(try CompressedTarUpdater.$testingStage.withValue({ if $0 == stage { throw CancellationError() } }) {
                try editor.commit()
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        for final in [false, true] {
            let output = root.appendingPathComponent("progress-\(final)")
            let editor = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
            try editor.rename(entryAt: 0, to: "large-C")
            XCTAssertThrowsError(try editor.commit { update in
                if !final || update.completedBytes == update.totalBytes { throw Stop.requested }
            }) { XCTAssertTrue($0 is Stop) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let output = root.appendingPathComponent("foreign"), moved = root.appendingPathComponent("moved")
        let replaced = Mutex(false)
        let editor = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
        XCTAssertThrowsError(try ZipCopyEngine.$writeObserver.withValue({ _, _ in
            let first = replaced.withLock { value in let first = !value; value = true; return first }
            if first { try? FileManager.default.moveItem(at: output, to: moved); try? Data([99]).write(to: output) }
        }) { try editor.commit() })
        XCTAssertEqual(try Data(contentsOf: output), Data([99]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
    func testTaskCancellationDuringEncodingAndCopy() async throws {
        let root = try TestSupport.directory("compressed-tar-task-cancellation")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip)
        for encoding in [true, false] {
            let output = root.appendingPathComponent("cancel-\(encoding)")
            let task = Task {
                let editor = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
                try editor.rename(entryAt: 0, to: "large-C")
                let count = Mutex(0), copying = Mutex(false)
                try CompressedTarUpdater.$testingStage.withValue({ stage in
                    if stage == .encoding {
                        let n = count.withLock { $0 += 1; return $0 }
                        if encoding && n == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                    if stage == .copying { copying.withLock { $0 = true } }
                }) {
                    try ZipCopyEngine.$testingBufferSize.withValue(32) {
                        try ZipCopyEngine.$writeObserver.withValue({ _, _ in
                            if !encoding && copying.withLock({ $0 }) { withUnsafeCurrentTask { $0?.cancel() } }
                        }) { try editor.commit() }
                    }
                }
            }
            do { try await task.value; XCTFail("cancelled task committed") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
    func testSourceChangesPathReplacementDiscardAndSpace() throws {
        let root = try TestSupport.directory("compressed-tar-lifecycle")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip, large: false)
        let original = try Data(contentsOf: source)
        let output = root.appendingPathComponent("output")
        var discarded: CompressedTarUpdater? = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
        try discarded!.add(data: Data([1]), as: "added"); discarded = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let originalID = try ZipEditTestSupport.info(source).st_ino
        let beforeSpaceFailure = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let scratchFD = Mutex<Int32>(-1)
        let failed = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
        XCTAssertThrowsError(try ScratchFile.$testingCreated.withValue({ fd in scratchFD.withLock { $0 = fd } }) {
            try ScratchFile.$testingFreeSpaceReserve.withValue(UInt64.max) { try failed.add(data: Data([1]), as: "added") }
        }) {
            XCTAssertEqual($0 as? WriterError, .io(operation: "free space", code: ENOSPC))
        }
        let fd = scratchFD.withLock { $0 }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try ZipEditTestSupport.info(source).st_ino, originalID)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), beforeSpaceFailure)
        XCTAssertThrowsError(try failed.commit()) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
        let changed = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: .tarGzip)
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try changed.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        try original.write(to: source)
        let reader = try CompressedTarTestSupport.open(source), base = reader.tarEditingSnapshot()!
        let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: .tarGzip)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("old"))
        try Data([99]).write(to: source)
        let result = try editor.commit(progress: nil)
        XCTAssertEqual(try Data(contentsOf: output), original)
        _ = try CompressedTarTestSupport.verify(output, base: base, result: result)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gyoshuku-splice-") })
    }
    func testFAT32() throws { try onDisk("MS-DOS FAT32") }
    func testExFAT() throws { try onDisk("ExFAT") }
    func testHostVolume() throws {
        try onVolume(TestSupport.directory("compressed-tar-host-lifecycle"), label: "host", expectsSmallVolume: false)
    }
    private func onDisk(_ fileSystem: String) throws {
        let disk = try ArchiveTestDisk(fileSystem)
        try onVolume(disk.mount, label: fileSystem, expectsSmallVolume: true)
        try disk.detach()
    }
    private func onVolume(_ volume: URL, label: String, expectsSmallVolume: Bool) throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.work(in: volume)
            let source = try CompressedTarTestSupport.fixture(root, format, large: false)
            try FileManager.default.removeItem(at: root.appendingPathComponent("input.tar"))
            let original = try Data(contentsOf: source)
            for operation in ["delete-first", "delete-last", "rename-same", "rename-long", "add", "unchanged", "cancel", "discard", "fault"] {
                let output = root.appendingPathComponent("output")
                var context = "\(label) \(format) \(operation), chunkMapUnavailableReason=<open pending>"
                do {
                    let reader = try CompressedTarTestSupport.open(source)
                    let base = try XCTUnwrap(reader.tarEditingSnapshot(), context)
                    context = "\(label) \(format) \(operation), chunkMapUnavailableReason=\(String(describing: base.chunkMapUnavailableReason)), chunks=\(base.chunkMap?.chunks.count ?? 0)"
                    TestSupport.report("COMPRESSED_TAR_LIFECYCLE \(context)")
                    var editor: CompressedTarUpdater? = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
                    if operation == "add", expectsSmallVolume {
                        var space = statfs()
                        XCTAssertEqual(statfs(root.path, &space), 0, context)
                        let available = UInt64(space.f_bavail) * UInt64(space.f_bsize)
                        XCTAssertGreaterThan(available, 0, context)
                        XCTAssertLessThan(available, 1024 * 1024 * 1024, context)
                    }
                    switch operation {
                    case "delete-first": try editor!.remove(entriesAt: [0])
                    case "delete-last": try editor!.remove(entriesAt: [26])
                    case "rename-same": try editor!.rename(entryAt: 0, to: "large-C")
                    case "rename-long": try editor!.rename(entryAt: 0, to: String(repeating: "n", count: 180))
                    case "add", "discard", "fault": try editor!.add(data: Data([1]), as: "added")
                    default: break
                    }
                    if operation == "discard" { editor = nil }
                    else if operation == "cancel" {
                        let calls = Mutex(0)
                        XCTAssertThrowsError(try CompressedTarUpdater.$testingStage.withValue({ stage in
                            if stage == .copying { calls.withLock { $0 += 1 }; throw CancellationError() }
                        }) { try editor!.commit() }, context) { XCTAssertTrue($0 is CancellationError, "\(context): \($0)") }
                        XCTAssertEqual(calls.withLock { $0 }, 1, "\(context): copying hook")
                    } else if operation == "fault" {
                        XCTAssertThrowsError(try CompressedTarUpdater.$testingFault.withValue(.flipEncodedByte) { try editor!.commit() }, context)
                    } else {
                        let calls = Mutex(0)
                        let result = try CompressedTarUpdater.$testingStage.withValue({ stage in
                            if stage == .copying { calls.withLock { $0 += 1 } }
                        }) { try editor!.commit(progress: nil) }
                        if operation == "unchanged" { XCTAssertEqual(calls.withLock { $0 }, 1, "\(context): copying hook") }
                        let verified = try CompressedTarTestSupport.verify(output, base: base, result: result)
                        if operation == "add" {
                            let added = try XCTUnwrap(verified.entries.first { $0.name == "added" }, context)
                            XCTAssertEqual(try verified.read(added), Data([1]), context)
                        }
                        try FileManager.default.removeItem(at: output)
                    }
                    editor = nil
                } catch { XCTFail("\(context): \(error)") }
                XCTAssertEqual(try Data(contentsOf: source), original, context)
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [source.lastPathComponent], context)
            }
        }
    }
}
