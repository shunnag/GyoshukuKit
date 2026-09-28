import Foundation
import Darwin
import Synchronization
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScaleTimingsAndIO() throws {
        guard let text = ProcessInfo.processInfo.environment["GYOSHUKU_TAR_SCALE_ENTRIES"], let count = Int(text), count > 2 else {
            throw XCTSkip("GYOSHUKU_TAR_SCALE_ENTRIES is not set")
        }
        let root = try TestSupport.directory("p2-scale-\(count)")
        let source = try TarP2Support.fixture(root, count: count, size: 1024)
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        TestSupport.report("TAR-SCALE editor\top\tentries\topen_ms\tremove_ms\trename_ms\tadd_ms\tcommit_ms\tverification_ms\tcopy_engine_writes\tverification_reads\toutput_bytes")
        for operation in ["delete-first", "delete-last", "rename-same", "rename-diff", "append", "replace"] {
            for rewrite in [false, true] {
                let output = root.appendingPathComponent("\(operation)-\(rewrite).tar")
                let start = now()
                let editor: any ArchiveEditing = rewrite
                    ? try ArchiveRewriter.open(url: source, output: output, format: .tar)
                    : try TarUpdater.open(url: source, output: output)
                let openTime = now() - start
                var remove = 0.0, rename = 0.0, add = 0.0
                if operation.hasPrefix("delete") || operation == "replace" {
                    let time = now()
                    try editor.remove(entriesAt: [operation == "delete-last" ? count - 1 : operation == "replace" ? count / 2 : 0])
                    remove = now() - time
                }
                if operation.hasPrefix("rename") {
                    let time = now()
                    try editor.rename(entryAt: count / 2, to: operation == "rename-same" ? "edit-000000" : String(repeating: "n", count: 150))
                    rename = now() - time
                }
                if operation == "append" || operation == "replace" {
                    let time = now()
                    try editor.add(data: Data(count: 1024), as: "added", modificationDate: TestSupport.date, permissions: 0o644)
                    add = now() - time
                }
                let writes = ZipIOEvents(), reads = ZipIOEvents(), verification = Mutex(0.0)
                let time = now()
                try SplicedArchiveOutput.$testingVerificationElapsed.withValue({ elapsed in verification.withLock { $0 = elapsed } }) {
                    try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                        try SplicedArchiveOutput.$verificationReadObserver.withValue(reads.write) { try editor.commit() }
                    }
                }
                let commit = now() - time
                let values = [openTime, remove, rename, add, commit, verification.withLock { $0 }].map { String(format: "%.3f", $0 * 1000) }
                TestSupport.report("TAR-SCALE \(rewrite ? "rewriter" : "updater")\t\(operation)\t\(count)\t" + values.joined(separator: "\t") + "\t\(writes.bytes)\t\(reads.bytes)\t\(try ZipUpdateSource(url: output).length)")
                try FileManager.default.removeItem(at: output)
            }
        }
    }
}
