import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterCancellationTests: XCTestCase {
    func testCancellationDuringCommitAndSequentialFirstAdd() async throws {
        for sequential in [false, true] {
            for duringAdd in [false, true] where sequential || !duringAdd {
                let root = try TestSupport.directory("p2-cancel-\(sequential)-\(duringAdd)")
                let source = try TarEditTestSupport.fixture(root, count: 8, size: 65536), work = try TestSupport.work(in: root)
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
            let root = try TestSupport.directory("p2-progress-\(action)")
            let source = try TarEditTestSupport.fixture(root), work = try TestSupport.work(in: root)
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
