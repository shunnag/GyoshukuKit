import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

final class ArchiveOwnedFileTests: XCTestCase {
    func testAssignedInodeRange() {
        let firstFake = ino_t(1) << 63
        for inode in [ino_t(1), 67, 263, ino_t(UInt32.max), firstFake - 1] {
            XCTAssertTrue(ArchiveOwnedFile.hasAssignedInode(inode), "inode \(inode)")
        }
        for inode in [firstFake, firstFake + 1, ino_t.max - 1024, ino_t.max - 4, ino_t.max - 3, ino_t.max - 1, ino_t.max] {
            XCTAssertFalse(ArchiveOwnedFile.hasAssignedInode(inode), "inode \(inode)")
        }
    }

    func testReplacedCloneIsNotAdoptedForCleanup() throws {
        for foreign in [Data(), Data([77])] {
            let root = try TestSupport.directory("owned-clone-\(foreign.count)")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.bin")
            let original = Data([1, 2, 3])
            try original.write(to: source)
            let snapshot = try ArchiveSourceSnapshot(url: source, directory: root, pathExtension: "bin")
            guard snapshot.snapshot != nil else { throw XCTSkip("clone unavailable on test volume") }
            let path = root.appendingPathComponent("output.bin"), moved = root.appendingPathComponent("moved.bin")
            let output = SegmentedArchiveOutput(snapshot: snapshot, output: path, pathExtension: "bin", sequential: false)
            let plan = SegmentCommitPlan(prefix: [.source(0..<3)], appended: nil, terminal: Data(),
                                         finalLength: 3, formatVerificationUnits: 0)
            try SegmentedArchiveOutput.$testingDidCloneOutput.withValue({ url in
                try FileManager.default.moveItem(at: url, to: moved)
                try foreign.write(to: url)
            }) {
                XCTAssertThrowsError(try output.commit(plan, meter: CommitProgressMeter(total: 0, progress: nil)) { _, _ in }) {
                    XCTAssertEqual($0 as? UpdaterError, .sourceChanged)
                }
            }
            output.discard()
            XCTAssertEqual(try Data(contentsOf: path), foreign)
            XCTAssertEqual(try Data(contentsOf: moved), original)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin", "output.bin", "moved.bin"])
        }
    }
}
