import Foundation
import XCTest
@testable import GyoshukuKit

final class ZipCommitCancellationTests: XCTestCase {
    func testChunkCancellationCleansBothModesAndPreservesSource() async throws {
        let directory = try TestSupport.directory("p1-cancel-chunk")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipEditTestSupport.fixture(directory, count: 4, payloadSize: 1024 * 1024)
        let before = try Data(contentsOf: source), inode = try ZipEditTestSupport.info(source).st_ino
        for outputMode in [false, true] {
            let parent = directory.appendingPathComponent("work-\(outputMode)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let events = IOEvents()
            let task = Task {
                let updater = try ArchiveUpdater.open(url: source, output: outputMode ? parent.appendingPathComponent("output.zip") : nil)
                try updater.remove(entriesAt: [0])
                try ZipCopyEngine.$testingBufferSize.withValue(16 * 1024) {
                    try ZipCopyEngine.$writeObserver.withValue({ offset, count in
                        events.write(offset, count)
                        if events.bytes >= 32 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
                    }) { try updater.commit() }
                }
            }
            do { try await task.value; XCTFail("expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try ZipEditTestSupport.info(source).st_ino, inode)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            XCTAssertEqual(events.bytes, 32 * 1024)
        }
    }

    func testPlanningCancellationAtIndexTwoWritesNothing() async throws {
        let directory = try TestSupport.directory("p1-cancel-plan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipEditTestSupport.fixture(directory)
        let before = try Data(contentsOf: source)
        let events = IOEvents()
        let task = Task {
            let updater = try ArchiveUpdater.open(url: source)
            try updater.remove(entriesAt: [4])
            updater.recordLayout = { index in
                if index == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return updater.validatedLayout(at: index)
            }
            try ZipCopyEngine.$writeObserver.withValue(events.write) { try updater.commit() }
        }
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events.bytes, 0)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
}
