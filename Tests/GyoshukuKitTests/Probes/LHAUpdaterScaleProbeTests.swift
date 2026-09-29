import Foundation
import Darwin
import KaitoKit
import Synchronization
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScale() throws {
        let count = try OptInGate.count("GYOSHUKU_LHA_SCALE_ENTRIES", minimum: 3)
        let root = try TestSupport.directory("lha-scale-\(count)"), source = root.appendingPathComponent("source.lzh")
        let data = Data(repeating: 65, count: 1024)
        let writer = try ArchiveWriter.create(url: source, format: .lha)
        for index in 0..<count { try writer.add(data: data, as: String(format: "file-%06d", index), modificationDate: TestSupport.date) }
        try writer.finish()
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func edit(_ editor: any ArchiveEditing, operation: String) throws {
            switch operation {
            case "first": try editor.remove(entriesAt: [0])
            case "last": try editor.remove(entriesAt: [count - 1])
            case "same": try editor.rename(entryAt: count / 2, to: String(format: "edit-%06d", count / 2))
            case "long": try editor.rename(entryAt: count / 2, to: "longer-name-than-before")
            case "replace": try editor.remove(entriesAt: [count / 2]); fallthrough
            default: try editor.add(data: data, as: "added", modificationDate: TestSupport.date, permissions: nil)
            }
        }
        var load = [Double](repeating: 0, count: 3); _ = getloadavg(&load, 3)
        ScaleProbe.report(tag: "LHA-SCALE", columns: ["entries", "operation", "engine", "open_ms", "edit_ms", "commit_ms",
            "V2_ms", "V3_ms", "V5_ms", "load1", "load5", "load15"])
        for operation in ["first", "last", "same", "long", "add", "replace"] {
            var openTimes: [Double] = []
            for rewrite in [false, true] {
                _ = getloadavg(&load, 3)
                let output = root.appendingPathComponent("\(operation)-\(rewrite).lzh"), started = now()
                let editor: any ArchiveEditing = try rewrite ? ArchiveRewriter.open(url: source, output: output, format: .lha)
                    : LHAUpdater.open(url: source, output: output)
                let opened = now()
                try edit(editor, operation: operation)
                let edited = now(), verification = Mutex(0.0)
                try SegmentedArchiveOutput.$testingVerificationElapsed.withValue({ duration in verification.withLock { $0 += duration } }) { try editor.commit() }
                let committed = now()
                let times = (editor as? LHAUpdater)?.verificationSeconds ?? (v2: 0.0, v3: 0.0, total: 0.0)
                let v5 = max(0, verification.withLock { $0 } - times.total)
                ScaleProbe.report(tag: "LHA-SCALE", columns: ["\(count)", operation, rewrite ? "rewriter" : "updater"]
                    + [opened - started, edited - opened, committed - edited, times.v2, times.v3, v5].map { String(format: "%.3f", $0 * 1000) }
                    + load.map { String(format: "%.2f", $0) })
                openTimes.append(opened - started)
                if count == 100000, !rewrite {
                    let limit: Double? = operation == "first" ? 150 : ["last", "same", "add"].contains(operation) ? 20 : nil
                    if let limit, !ScaleProbe.threshold((committed - edited) * 1000, limit: limit, "\(operation) commit_ms") {
                        ScaleProbe.report(tag: "LHA-SCALE-MISS", columns: [operation, "commit_limit_ms=\(limit)"])
                    }
                }
                try FileManager.default.removeItem(at: output)
            }
            if count == 100000, !ScaleProbe.threshold(openTimes[0], limit: openTimes[1] * 1.25, "\(operation) updater/rewriter open ratio") {
                ScaleProbe.report(tag: "LHA-SCALE-MISS", columns: [operation, "open_ratio=\(openTimes[0] / openTimes[1])", "limit=1.25"])
            }
        }
        let empty = root.appendingPathComponent("empty.lzh"), output = root.appendingPathComponent("text.lzh")
        try Data([0]).write(to: empty)
        let editor = try LHAUpdater.open(url: empty, output: output)
        let text = Data(repeating: 0x61, count: 256 << 20), start = now()
        try editor.add(data: text, as: "text256.txt", modificationDate: TestSupport.date)
        let encoded = now()
        try editor.commit()
        ScaleProbe.report(tag: "LHA-SCALE-TEXT", columns: ["bytes=\(text.count)", String(format: "encode_ms=%.3f", (encoded - start) * 1000),
            String(format: "V3_ms=%.3f", editor.verificationSeconds.v3 * 1000), String(format: "commit_ms=%.3f", (now() - encoded) * 1000)])
    }
}
