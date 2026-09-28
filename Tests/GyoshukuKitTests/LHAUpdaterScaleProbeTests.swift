import Foundation
import Darwin
import KaitoKit
import Synchronization
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScale() throws {
        guard let value = ProcessInfo.processInfo.environment["GYOSHUKU_LHA_SCALE_ENTRIES"], let count = Int(value), count > 2 else {
            throw XCTSkip("Set GYOSHUKU_LHA_SCALE_ENTRIES=100000; use -c release -Xswiftc -enable-testing")
        }
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
        print("LHA-SCALE\tentries\toperation\tengine\topen_ms\tedit_ms\tcommit_ms\tV2_ms\tV3_ms\tV5_ms\tload1\tload5\tload15")
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
                try SplicedArchiveOutput.$testingVerificationElapsed.withValue({ duration in verification.withLock { $0 += duration } }) { try editor.commit() }
                let committed = now()
                let times = (editor as? LHAUpdater)?.verificationSeconds ?? (v2: 0.0, v3: 0.0, total: 0.0)
                let v5 = max(0, verification.withLock { $0 } - times.total)
                print(String(format: "LHA-SCALE\t%d\t%@\t%@\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.2f\t%.2f\t%.2f", count, operation, rewrite ? "rewriter" : "updater", (opened - started) * 1000, (edited - opened) * 1000, (committed - edited) * 1000, times.v2 * 1000, times.v3 * 1000, v5 * 1000, load[0], load[1], load[2]))
                openTimes.append(opened - started)
                if count == 100000, !rewrite {
                    let limit: Double? = operation == "first" ? 150 : ["last", "same", "add"].contains(operation) ? 20 : nil
                    if let limit, (committed - edited) * 1000 > limit { print("LHA-SCALE-MISS\t\(operation)\tcommit_limit_ms=\(limit)") }
                }
                try FileManager.default.removeItem(at: output)
            }
            if count == 100000, openTimes[0] > openTimes[1] * 1.25 { print("LHA-SCALE-MISS\t\(operation)\topen_ratio=\(openTimes[0] / openTimes[1])\tlimit=1.25") }
        }
        let empty = root.appendingPathComponent("empty.lzh"), output = root.appendingPathComponent("text.lzh")
        try Data([0]).write(to: empty)
        let editor = try LHAUpdater.open(url: empty, output: output)
        let text = Data(repeating: 0x61, count: 256 << 20), start = now()
        try editor.add(data: text, as: "text256.txt", modificationDate: TestSupport.date)
        let encoded = now()
        try editor.commit()
        print(String(format: "LHA-SCALE-TEXT\tbytes=%d\tencode_ms=%.3f\tV3_ms=%.3f\tcommit_ms=%.3f", text.count, (encoded - start) * 1000, editor.verificationSeconds.v3 * 1000, (now() - encoded) * 1000))
    }
}
