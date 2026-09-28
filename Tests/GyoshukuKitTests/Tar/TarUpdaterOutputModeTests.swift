import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterOutputModeTests: XCTestCase {
    func testSourceSnapshotFlagsCloneErrorsAndOutputValidation() throws {
        let root = try TestSupport.directory("p2-output-identity")
        let source = try TarEditTestSupport.fixture(root), work = try TestSupport.work(in: root)
        let output = work.appendingPathComponent("out.tar")
        let original = try ZipEditTestSupport.info(source)
        let reads = ZipIOEvents()
        var updater: TarUpdater? = try ZipUpdateSource.$readObserver.withValue(reads.read) { try TarUpdater.open(url: source, output: output) }
        XCTAssertFalse(reads.events.isEmpty)
        XCTAssertTrue(reads.events.allSatisfy { $0.inode != UInt64(original.st_ino) })
        let snapshot = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try ZipEditTestSupport.info(snapshot).st_flags, 0)
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
                    let root = try TestSupport.directory("p2-clean-\(sequential)-\(action)")
                    let source = try TarEditTestSupport.fixture(root), work = try TestSupport.work(in: root)
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
