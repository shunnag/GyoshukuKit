import Foundation
import Darwin
import Synchronization
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterCancellationTests: XCTestCase {
    func testCancellationDuringScratchConversionVerificationAndRelocation() async throws {
        for phase in ["scratch", "generated", "verification", "relocation", "relocation-return"] {
            let root = try TestSupport.directory("7z-cancel-" + phase)
            let source = phase == "scratch" ? SevenZipEditSupport.fixture("m") : try SevenZipEditSupport.source(root)
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
            let fired = Mutex(false)
            let task = Task {
                let updater = try SevenZipUpdater.open(url: source, output: output, options: WriterOptions(password: phase == "generated" ? "secret" : nil))
                if phase == "scratch" {
                    try updater.remove(entriesAt: [updater.filesByFolder.first { $0.count > 1 }!.first!])
                } else if phase == "generated" { try updater.reencryptExistingEntries(currentPassword: nil) }
                else {
                    try updater.add(data: Data(repeating: 42, count: 1000), as: "addition")
                    if phase.hasPrefix("relocation") { try updater.remove(entriesAt: [0]) }
                }
                if phase == "verification" {
                    let position = updater.appendStart!
                    try ArchiveFileSource.$readObserver.withValue({ _, offset, _ in
                        if offset == position { fired.withLock { $0 = true }; withUnsafeCurrentTask { $0?.cancel() } }
                    }) { try updater.commit() }
                } else {
                    let returnOffset = updater.model.mainPackEnd - updater.model.packs[0].length
                    // A small copy buffer forces cancellation inside the generator / spool copy,
                    // rather than only when the final tail flushes a small archive.
                    try ZipCopyEngine.$testingBufferSize.withValue(phase == "relocation-return" ? 1 : 64) {
                    try ZipCopyEngine.$writeObserver.withValue({ offset, _ in
                        if phase == "relocation-return" && offset != returnOffset { return }
                        fired.withLock { $0 = true }; withUnsafeCurrentTask { $0?.cancel() }
                    }) { try updater.commit() }
                    }
                }
            }
            do { try await task.value; XCTFail("cancel did not throw: \(phase)") }
            catch { XCTAssertTrue(error is CancellationError, "\(phase): \(error)") }
            XCTAssertTrue(fired.withLock { $0 }, phase)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], phase)
        }
    }
}
