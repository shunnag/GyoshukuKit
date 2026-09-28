import Foundation
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipCommitProgressTests: XCTestCase {
    func testAllSixStrategiesCountExactlyWrittenBytesWithBoundedNotifications() throws {
        let directory = try TestSupport.directory("p1-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory, count: 3, payloadSize: 5 * 1024 * 1024)
        let cases: [([ZipP1Support.Operation], ArchiveUpdater.CommitStrategy)] = [
            ([], .unchanged), ([.add("added", Data([1]))], .appendOnly),
            ([.rename(0, "other-000000.txt")], .inPlacePatch), ([.remove([0])], .rebuild),
            ([.remove([0]), .add("added", Data([1]))], .rebuildThenAppend),
            ([.add("added", Data([1])), .remove([0])], .stagedRebuild)
        ]
        for (index, item) in cases.enumerated() {
            let output = directory.appendingPathComponent("out-\(index).zip")
            let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(compressionMethod: .stored))
            try ZipP1Support.mutate(updater, item.0)
            let events = ZipIOEvents()
            var progress: [ArchiveUpdater.CommitProgress] = []
            try ZipCopyEngine.$writeObserver.withValue(events.write) {
                try updater.commit { progress.append($0) }
            }
            XCTAssertEqual(updater.lastCommitStrategy, item.1)
            let last = try XCTUnwrap(progress.last)
            XCTAssertEqual(progress.first?.completedBytes, 0)
            XCTAssertEqual(last.completedBytes, last.totalBytes)
            XCTAssertEqual(last.totalBytes, events.bytes)
            XCTAssertTrue(progress.allSatisfy { $0.totalBytes == last.totalBytes }, "no total correction")
            XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
            XCTAssertLessThanOrEqual(progress.count, Int((events.bytes + 4 * 1024 * 1024 - 1) / (4 * 1024 * 1024)) + 2)
        }
    }

    func testThrowAtInitialIntermediateAndFinalProgressRemovesOutput() throws {
        let directory = try TestSupport.directory("p1-progress-throw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory, count: 3, payloadSize: 5 * 1024 * 1024)
        let original = try Data(contentsOf: source), inode = try ZipP1Support.info(source).st_ino
        for when in 0..<3 {
            let parent = directory.appendingPathComponent("work-\(when)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let updater = try ArchiveUpdater.open(url: source, output: parent.appendingPathComponent("output.zip"))
            try updater.remove(entriesAt: [0])
            XCTAssertThrowsError(try updater.commit { progress in
                if (when == 0 && progress.completedBytes == 0)
                    || (when == 1 && progress.completedBytes > 0)
                    || (when == 2 && progress.completedBytes == progress.totalBytes) { throw WriterError.sizeOverflow }
            }) { XCTAssertEqual($0 as? WriterError, .sizeOverflow) }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try ZipP1Support.info(source).st_ino, inode)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            XCTAssertThrowsError(try updater.commit())
        }
    }
}
