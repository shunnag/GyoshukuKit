import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterRefusalTests: XCTestCase {
    func testHardLinkRawNameGuardAndLegacyEncodingFallback() throws {
        let root = try ZipTestSupport.directory("p2-raw-link-refusal")
        let source = root.appendingPathComponent("source.tar")
        let raw = Data([0x93, 0xfa, 0x96, 0x7b])
        let file = TarRecords.Entry(name: raw).ustar()
        let link = TarRecords.Entry(name: Data("link".utf8), type: 0x31, link: raw).ustar()
        try (file + link + Data(count: 1024)).write(to: source)
        let data = try ZipUpdateSource(url: source)
        let reader = try ArchiveReader.open(url: source)
        XCTAssertNotNil(reader.nameEncoding)
        let gate = try ArchiveRewriter.validateRepresentability(entries: reader.entries, format: .tar, reader: reader)
        // R10 が先に拒否する入力でも、共有 walk の R6 を独立して確かめる。
        XCTAssertThrowsError(try TarLayout.scan(source: data, length: data.length, entries: reader.entries, nameEncoding: nil,
                                                hardLinkTargets: gate.hardLinkTargets, dataTargets: gate.dataTargets)) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R6"))
        }
        let work = try TarP2Support.work(root)
        XCTAssertThrowsError(try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"))) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R10"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testSettingsNamesAndStructuralRefusalsLeaveNothing() throws {
        let root = try ZipTestSupport.directory("p2-refusals")
        let member = TarRecords.Entry(name: Data("file".utf8)).headers()
        var oldSparse = TarRecords.Entry(name: Data("sparse".utf8), type: 0x53).ustar()
        oldSparse.replaceSubrange(257..<265, with: Data("ustar  \0".utf8))
        TarP2Support.checksum(&oldSparse)
        let hard = TarRecords.Entry(name: Data("link".utf8), size: 1, type: 0x31, link: Data("file".utf8)).headers()
        let local = TarP2Support.extensionBytes(0x78, TarRecords.paxRecord("mtime", value: Data("1".utf8)))
        let global = TarP2Support.extensionBytes(0x67, TarRecords.paxRecord("comment", value: Data("test".utf8)))
        let sparse = TarP2Support.extensionBytes(0x78, TarRecords.paxRecord("GNU.sparse.size", value: Data("0".utf8))
            + TarRecords.paxRecord("GNU.sparse.map", value: Data("0,0".utf8))) + member
        let cases: [(String, Data, WriterOptions, String)] = [
            ("begin.tar", member, .init(additionPlacement: .beginning), "additionPlacement"),
            ("reset.tar", member, .init(carriedTarOwnerIDs: .reset), "carriedTarOwnerIDs"),
            ("global.tar", TarP2Support.extensionBytes(0x67, TarRecords.paxRecord("uid", value: Data("501".utf8))) + member, .init(), "R1"),
            ("pending.tar", local + global + member, .init(), "R1"),
            ("old-sparse.tar", oldSparse, .init(), "R2"),
            ("hard-body.tar", member + hard, .init(), "R3"),
            ("charset.tar", TarP2Support.extensionBytes(0x78, TarRecords.paxRecord("hdrcharset", value: Data("UTF-8".utf8))) + member, .init(), "R4"),
            ("sparse-link.tar", sparse + TarRecords.Entry(name: Data("link".utf8), type: 0x31, link: Data("file".utf8)).headers(), .init(), "R5"),
            ("split.tar.001", member, .init(), "split volume name")
        ]
        for (name, bytes, options, reason) in cases {
            let source = root.appendingPathComponent(name)
            try (bytes + Data(count: 1024)).write(to: source)
            let work = try TarP2Support.work(root)
            let info = try ZipP1Support.info(source)
            XCTAssertThrowsError(try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"), options: options)) {
                guard case TarUpdaterError.requiresRewrite(let text) = $0 else { return XCTFail("\(name): \($0)") }
                XCTAssertTrue(text.contains(reason), "\(name): \(text)")
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes + Data(count: 1024))
            XCTAssertEqual(try ZipP1Support.info(source).st_ino, info.st_ino)
            XCTAssertEqual(try ZipP1Support.info(source).st_mtimespec.tv_nsec, info.st_mtimespec.tv_nsec)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }

    func testMismatchEncodingAndKaitoErrorsStayDistinct() throws {
        let root = try ZipTestSupport.directory("p2-refusal-errors")
        let source = try TarP2Support.fixture(root)
        let work = try TarP2Support.work(root), output = work.appendingPathComponent("out.tar")
        try TarLayout.$testingKaitoKitMismatch.withValue(true) {
            XCTAssertThrowsError(try TarUpdater.open(url: source, output: output)) {
                guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(reason.contains("R8"))
            }
        }
        var cp932 = TarRecords.Entry(name: Data("name".utf8)).ustar()
        cp932.replaceSubrange(0..<4, with: Data([0x93, 0xfa, 0x96, 0x7b]))
        TarP2Support.checksum(&cp932)
        let legacy = root.appendingPathComponent("legacy.tar")
        try (cp932 + Data(count: 1024)).write(to: legacy)
        XCTAssertThrowsError(try TarUpdater.open(url: legacy, output: output)) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R10"))
        }
        let extensionBytes = TarP2Support.extensionBytes(0x78, TarRecords.paxRecord("path", value: Data("file".utf8)))
        for bytes in [extensionBytes + extensionBytes + TarRecords.Entry(name: Data("file".utf8)).headers(), extensionBytes] {
            let malformed = root.appendingPathComponent(UUID().uuidString + ".tar")
            try (bytes + Data(count: 1024)).write(to: malformed)
            XCTAssertThrowsError(try TarUpdater.open(url: malformed, output: output)) { XCTAssertTrue($0 is KaitoError, "\($0)") }
        }
        let gzip = root.appendingPathComponent("gzip.tar")
        let writer = try ArchiveWriter.create(url: gzip, format: .tarGzip)
        try writer.add(data: Data(), as: "file")
        try writer.finish()
        XCTAssertThrowsError(try TarUpdater.open(url: gzip, output: output)) {
            guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
}

final class TarUpdaterOutputModeTests: XCTestCase {
    func testSourceSnapshotFlagsCloneErrorsAndOutputValidation() throws {
        let root = try ZipTestSupport.directory("p2-output-identity")
        let source = try TarP2Support.fixture(root), work = try TarP2Support.work(root)
        let output = work.appendingPathComponent("out.tar")
        let original = try ZipP1Support.info(source)
        let reads = ZipIOEvents()
        var updater: TarUpdater? = try ZipUpdateSource.$readObserver.withValue(reads.read) { try TarUpdater.open(url: source, output: output) }
        XCTAssertFalse(reads.events.isEmpty)
        XCTAssertTrue(reads.events.allSatisfy { $0.inode != UInt64(original.st_ino) })
        let snapshot = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try ZipP1Support.info(snapshot).st_flags, 0)
        updater = nil
        XCTAssertNil(updater)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        for error in [EIO, EPERM, ENOTSUP, EXDEV] {
            try ArchiveSourceSnapshot.$testingCloneError.withValue(error) {
                if error == ENOTSUP || error == EXDEV {
                    let editor = try TarUpdater.open(url: source, output: output)
                    try editor.remove(entriesAt: [0])
                    try editor.commit()
                    XCTAssertEqual(editor.lastCommitStrategy, .sequential)
                    try FileManager.default.removeItem(at: output)
                } else {
                    XCTAssertThrowsError(try TarUpdater.open(url: source, output: output)) { XCTAssertEqual($0 as? WriterError, .io(operation: "clone source", code: error)) }
                }
            }
        }
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        XCTAssertThrowsError(try TarUpdater.open(url: source, output: output)) { XCTAssertEqual($0 as? WriterError, .io(operation: "source flags", code: EPERM)) }
        _ = chflags(source.path, 0)
        try Data([1]).write(to: output)
        XCTAssertThrowsError(try TarUpdater.open(url: source, output: output)) { guard case WriterError.invalidPath = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try TarUpdater.open(url: source, output: work.appendingPathComponent("missing/out"))) { guard case WriterError.invalidPath = $0 else { return XCTFail("\($0)") } }
    }

    func testSourceChangeAbandonAndReplacementInodesInBothModes() throws {
        for sequential in [false, true] {
            for action in 0..<4 {
                try TarUpdater.$testingDisablesClone.withValue(sequential) {
                    let root = try ZipTestSupport.directory("p2-clean-\(sequential)-\(action)")
                    let source = try TarP2Support.fixture(root), work = try TarP2Support.work(root)
                    let output = work.appendingPathComponent("out.tar")
                    var editor: TarUpdater? = try TarUpdater.open(url: source, output: output)
                    if action != 0 { try editor!.add(data: Data([7]), as: "added") }
                    if action == 0 || action == 1 {
                        let file = try FileHandle(forWritingTo: source)
                        try file.seek(toOffset: 512)
                        try file.write(contentsOf: Data([33]))
                        try file.close()
                        XCTAssertThrowsError(try editor!.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
                    } else if action == 3 {
                        try FileManager.default.removeItem(at: output)
                        try Data([88]).write(to: output)
                    }
                    editor = nil
                    if action == 3 { XCTAssertEqual(try Data(contentsOf: output), Data([88])) }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), action == 3 ? ["out.tar"] : [])
                }
            }
        }
    }
}

final class TarUpdaterVerificationFaultTests: XCTestCase {
    func testV1ThroughV5RejectCorruptionAndCleanUp() throws {
        for kind in 0..<5 {
            let root = try ZipTestSupport.directory("p2-fault-\(kind)")
            let source = try TarP2Support.fixture(root), work = try TarP2Support.work(root)
            let before = try Data(contentsOf: source)
            let output = work.appendingPathComponent("out.tar")
            let editor = try TarUpdater.open(url: source, output: output)
            let fault: TarUpdater.Fault
            switch kind {
            case 0: try editor.rename(entryAt: 0, to: "new"); fault = .corruptWrittenHeader
            case 1: try editor.remove(entriesAt: [5]); fault = .flipWrittenByte(0)
            case 2: try editor.add(data: Data([1]), as: "new"); fault = .corruptWrittenHeader
            case 3: try editor.remove(entriesAt: [5]); fault = .dropTerminatorBlock
            default: try editor.remove(entriesAt: [0]); fault = .shiftSourceSegment
            }
            try TarUpdater.$testingFault.withValue(fault) {
                XCTAssertThrowsError(try editor.commit()) {
                    guard case TarUpdaterError.outputVerificationFailed(let reason) = $0 else { return XCTFail("\($0)") }
                    if kind != 2 { XCTAssertTrue(reason.contains("V\(kind + 1)"), reason) }
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
}

final class TarUpdaterCancellationTests: XCTestCase {
    func testCancellationDuringCommitAndSequentialFirstAdd() async throws {
        for sequential in [false, true] {
            for duringAdd in [false, true] where sequential || !duringAdd {
                let root = try ZipTestSupport.directory("p2-cancel-\(sequential)-\(duringAdd)")
                let source = try TarP2Support.fixture(root, count: 8, size: 65536), work = try TarP2Support.work(root)
                let before = try Data(contentsOf: source)
                let task = Task {
                    try TarUpdater.$testingDisablesClone.withValue(sequential) {
                        let editor = try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"))
                        try editor.remove(entriesAt: [0])
                        try ZipCopyEngine.$testingBufferSize.withValue(16384) {
                            try ZipCopyEngine.$writeObserver.withValue({ _, _ in withUnsafeCurrentTask { $0?.cancel() } }) {
                                if duringAdd { try editor.add(data: Data(), as: "new") }
                                else { try editor.commit() }
                            }
                        }
                    }
                }
                do { try await task.value; XCTFail("expected cancellation") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
            }
        }
    }

    func testProgressThrowsAndAllReentrantOperationsInvalidateCommit() throws {
        for action in 0..<6 {
            let root = try ZipTestSupport.directory("p2-progress-\(action)")
            let source = try TarP2Support.fixture(root), work = try TarP2Support.work(root)
            let editor = try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"))
            try editor.add(data: Data(), as: "added")
            XCTAssertThrowsError(try editor.commit { update in
                if action == 5, update.completedBytes == 0 { return }
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
}
