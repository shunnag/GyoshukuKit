import Foundation
import Darwin
import Synchronization
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScaleTimingsAndIO() throws {
        let count = try OptInGate.count("GYOSHUKU_TAR_SCALE_ENTRIES", minimum: 3)
        let root = try TestSupport.directory("p2-scale-\(count)")
        let source = try TarEditTestSupport.fixture(root, count: count, size: 1024)
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        ScaleProbe.report(tag: "TAR-SCALE", columns: ["editor", "op", "entries", "open_ms", "remove_ms", "rename_ms", "add_ms",
            "commit_ms", "verification_ms", "copy_engine_writes", "verification_reads", "output_bytes"])
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
                let writes = IOEvents(), reads = IOEvents(), verification = Mutex(0.0)
                let time = now()
                try SegmentedArchiveOutput.$testingVerificationElapsed.withValue({ elapsed in verification.withLock { $0 = elapsed } }) {
                    try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                        try SegmentedArchiveOutput.$verificationReadObserver.withValue(reads.write) { try editor.commit() }
                    }
                }
                let commit = now() - time
                let values = [openTime, remove, rename, add, commit, verification.withLock { $0 }].map { String(format: "%.3f", $0 * 1000) }
                ScaleProbe.report(tag: "TAR-SCALE", columns: [rewrite ? "rewriter" : "updater", operation, "\(count)"] + values
                    + ["\(writes.bytes)", "\(reads.bytes)", "\(try ArchiveFileSource(url: output).length)"])
                try FileManager.default.removeItem(at: output)
            }
        }
    }
}
