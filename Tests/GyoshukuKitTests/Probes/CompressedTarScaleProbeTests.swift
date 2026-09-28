import Foundation
import Darwin
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarScaleProbeTests: XCTestCase {
    func testMixedNewAndOldLayouts() throws {
        try OptInGate.flag("GYOSHUKU_SCALE_PROBES")
        let corpus = try OptInGate.path("GYOSHUKU_SCALE_CORPUS").appendingPathComponent("arc")
        let root = try TestSupport.directory("compressed-tar-scale")
        let raw = corpus.appendingPathComponent("mixed.tar")
        let options = WriterOptions(compressionThreads: 8)
        // 合計 3 分待っても下がらない負荷は、そのまま記録し、時間の閾値は変えない。
        var loadWaitBudget = 180
        ScaleProbe.report(tag: "TAR-SCALE", columns: ["layout", "codec", "operation", "stage", "wall_ms", "plan_ms", "encode_worker_ms",
            "copy_ms", "selfcheck_ms", "reencoded_bytes", "reencoded_old_bytes", "carried_bytes", "carried_chunks", "encoded_chunks",
            "scratch_bytes", "output_bytes", "load1", "load5", "load15", "limit_ms", "load_wait_s"])
        for format in CompressedTarTestSupport.formats {
            let suffix = format == .tarGzip ? "tgz" : format == .tarBzip2 ? "tbz" : "txz"
            let fresh: URL
            if let directory = OptInGate.value("GYOSHUKU_SCALE_NEW_ARCHIVES") {
                fresh = URL(fileURLWithPath: directory).appendingPathComponent("mixed-8.\(suffix)")
            } else {
                fresh = root.appendingPathComponent("fresh.\(suffix)")
                let writer = try ArchiveRewriter.open(url: raw, output: fresh, format: format, options: options)
                try writer.commit()
            }
            try XCTAssertByteSourcesEqual(CompressedTarTestSupport.open(fresh).tarEditingSnapshot()!.image, FileByteSource(url: raw))
            for layout in ["new", "old"] {
                let source = layout == "new" ? fresh : corpus.appendingPathComponent("mixed.\(suffix)")
                let reader = try CompressedTarTestSupport.open(source)
                let base = reader.tarEditingSnapshot()!
                let small = reader.entries.filter { $0.kind == .file && $0.name.hasPrefix("small/") }
                let entry = try XCTUnwrap(small.isEmpty ? nil : small[small.count / 2])
                let operations = ["append", "delete-small", "rename-same", "rename-different"] + (format == .tarXZ ? ["rename-text256"] : [])
                for operation in operations {
                    let output = root.appendingPathComponent("\(layout)-\(operation).\(suffix)")
                    let updater = try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: format, options: options)
                    if operation == "append" {
                        try updater.add(data: Data(repeating: 65, count: 4096), as: "added.txt", modificationDate: TestSupport.date)
                    } else if operation == "delete-small" { try updater.remove(entriesAt: [entry.index]) }
                    else if operation == "rename-text256" {
                        let text = try XCTUnwrap(reader.entries.first { $0.name == "text256.txt" })
                        try updater.rename(entryAt: text.index, to: "renamed-text256.txt")
                    } else {
                        let name = operation == "rename-same" ? "r" + entry.name.dropFirst() : "renamed/" + String(repeating: "n", count: 160)
                        try updater.rename(entryAt: entry.index, to: String(name))
                    }
                    let (load, waited) = try ScaleProbe.waitForLoad(below: 4, budget: &loadWaitBudget)
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = try updater.commit(progress: nil)
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let statistics = try XCTUnwrap(updater.lastCommitStatistics)
                    let verifyStart = ProcessInfo.processInfo.systemUptime
                    let verified = try CompressedTarTestSupport.spliceVerifiedReader(output, base: base, result: result)
                    let k5 = ProcessInfo.processInfo.systemUptime - verifyStart
                    let limit: Double
                    if format == .tarGzip { limit = layout == "new" ? 0.6 : 0.9 }
                    else if format == .tarBzip2 { limit = layout == "new" ? 1.2 : 1.8 }
                    else if operation == "append" || operation == "rename-text256" { limit = layout == "new" ? 1.0 : .infinity }
                    else { limit = layout == "new" ? 1.5 : .infinity }
                    let stats = [statistics.planningSeconds, statistics.encodingSeconds, statistics.copyingSeconds, statistics.selfCheckSeconds]
                        .map { String(format: "%.3f", $0 * 1000) }
                    let bytes = [result.reencodedImageBytes, result.reencodedOldImageBytes, result.carriedCompressedBytes].map(String.init)
                    let counts = ["\(statistics.carriedChunks)", "\(statistics.reencodedChunks)", "\(statistics.scratchBytes)", "\(result.output.size)"]
                    let loads = load.map { String(format: "%.2f", $0) }
                    for (stage, seconds) in [("commit", elapsed), ("k5", k5)] {
                        ScaleProbe.report(tag: "TAR-SCALE", columns: [layout, suffix, operation, stage, String(format: "%.3f", seconds * 1000)]
                            + stats + bytes + counts + loads + [String(format: "%.3f", limit * 1000), "\(waited)"])
                    }
                    ScaleProbe.threshold(elapsed, limit: limit, "\(layout) \(suffix) \(operation), load \(load)")
                    XCTAssertLessThanOrEqual(statistics.scratchBytes, UInt64((operation == "append" ? 4096 : 0) + 1048576))
                    if layout == "new", operation == "append" { XCTAssertEqual(result.reencodedOldImageBytes, 0) }
                    let full = try CompressedTarTestSupport.open(output)
                    XCTAssertEqual(verified.entries.map(\.name), full.entries.map(\.name))
                    try XCTAssertByteSourcesEqual(verified.tarEditingSnapshot()!.image, full.tarEditingSnapshot()!.image)
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }
}


extension CompressedTarScaleProbeTests {
    func testXZPackingArchives() throws {
        let archives = try OptInGate.path("GYOSHUKU_P14_ARCHIVES")
        let assertsTime = ScaleProbe.assertsThresholds(alias: "GYOSHUKU_P14_ASSERT")
        let root = try TestSupport.directory("xz-packing-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        let options = WriterOptions(compressionThreads: 8)
        var loadWaitBudget = 180, sequence = 0
        ScaleProbe.report(tag: "TAR-XZ-PACKING", columns: ["archive", "operation", "commit_ms", "k5_ms", "open_ms", "strategy",
            "reencoded_bytes", "reencoded_old_bytes", "carried_bytes", "carried_chunks", "reencoded_chunks", "encodingSeconds",
            "selfCheckSeconds", "load1", "load5", "load15", "load_wait_s"])

        // 親 commit へこのファイルだけを写しても実行できる API に限る。
        func run(_ source: URL, name: String, operation: String) throws -> URL {
            let reader = try CompressedTarTestSupport.open(source)
            let base = try XCTUnwrap(reader.tarEditingSnapshot())
            let prefix = name.contains("mixed") ? "small/" : name.contains("payload") ? "payload/" : "mid/"
            let files = reader.entries.filter { $0.kind == .file }
            let small = files.filter { $0.name.hasPrefix(prefix) }
            let candidates = operation.contains("small") ? small : files
            let middle = try XCTUnwrap(candidates.isEmpty ? nil : candidates[candidates.count / 2])
            let output = root.appendingPathComponent("\(sequence)-\(name)-\(operation).tar.xz")
            sequence += 1
            let updater = try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tarXZ, options: options)
            switch operation {
            case "append":
                try updater.add(data: Data(repeating: 65, count: 4096), as: "p14-added.txt", modificationDate: TestSupport.date)
            case "rename-folder":
                let folder = try XCTUnwrap(reader.entries.first { $0.kind == .directory && $0.name == prefix })
                try updater.rename(entryAt: folder.index, to: "r" + prefix.dropFirst())
            case "rename-text256":
                let text = try XCTUnwrap(files.first { $0.name == "text256.txt" })
                try updater.rename(entryAt: text.index, to: "renamed-text256.txt")
            default:
                if operation.hasPrefix("delete") { try updater.remove(entriesAt: [middle.index]) }
                else { try updater.rename(entryAt: middle.index, to: "renamed/" + middle.name) }
            }
            let (load, waited) = try ScaleProbe.waitForLoad(below: 4, budget: &loadWaitBudget)
            let started = ProcessInfo.processInfo.systemUptime
            let result = try updater.commit(progress: nil)
            let commit = ProcessInfo.processInfo.systemUptime - started
            let statistics = try XCTUnwrap(updater.lastCommitStatistics)
            let k5Start = ProcessInfo.processInfo.systemUptime
            let verified = try CompressedTarTestSupport.spliceVerifiedReader(output, base: base, result: result)
            let k5 = ProcessInfo.processInfo.systemUptime - k5Start
            let openStart = ProcessInfo.processInfo.systemUptime
            let full = try CompressedTarTestSupport.open(output)
            let open = ProcessInfo.processInfo.systemUptime - openStart
            XCTAssertEqual(verified.entries.map(\.name), full.entries.map(\.name))
            XCTAssertEqual(verified.entries.map(\.kind), full.entries.map(\.kind))
            let times = [commit, k5, open].map { String(format: "%.3f", $0 * 1000) }
            let bytes = [result.reencodedImageBytes, result.reencodedOldImageBytes, result.carriedCompressedBytes].map(String.init)
            let counts = ["\(statistics.carriedChunks)", "\(statistics.reencodedChunks)"]
            let seconds = [statistics.encodingSeconds, statistics.selfCheckSeconds].map { String(format: "%.6f", $0) }
            let loads = load.map { String(format: "%.2f", $0) }
            ScaleProbe.report(tag: "TAR-XZ-PACKING", columns: [name, operation] + times + ["\(result.strategy)"] + bytes
                + counts + seconds + loads + ["\(waited)"])
            if let limit = Self.xzPackingCommitLimit(name: name, operation: operation) {
                ScaleProbe.threshold(commit, limit: limit, assert: assertsTime, "\(name) \(operation), load \(load)")
            }
            return output
        }

        for name in ["mixed", "payload", "mid", "old-mixed", "old-payload", "old-mid"] {
            let source = archives.appendingPathComponent(name + ".tar.xz")
            if name.hasPrefix("old-"), !FileManager.default.fileExists(atPath: source.path) { continue }
            if name == "old-mixed" {
                let first = try run(source, name: name, operation: "delete-small")
                let second = try run(first, name: name, operation: "delete-small-second")
                try FileManager.default.removeItem(at: first)
                try FileManager.default.removeItem(at: second)
                let folder = try run(source, name: name, operation: "rename-folder")
                try FileManager.default.removeItem(at: folder)
                continue
            }
            let operations: [String]
            if name.hasPrefix("old-") { operations = ["delete-middle", "rename-middle", "rename-folder"] }
            else {
                operations = ["append", "delete-middle", "rename-middle", "rename-folder"]
                    + (name == "mixed" ? ["delete-small", "rename-small", "rename-text256"] : [])
            }
            for operation in operations {
                let output = try run(source, name: name, operation: operation)
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    private static func xzPackingCommitLimit(name: String, operation: String) -> Double? {
        if name == "old-mixed" {
            if operation == "delete-small" { return 1.6 }
            if operation == "delete-small-second" { return 1.2 }
        }
        if name == "mixed" {
            if operation == "append" || operation == "rename-text256" { return 0.060 }
            if operation == "delete-small" || operation == "rename-small" { return 1.2 }
        }
        if name == "payload" || name == "mid" {
            if operation == "rename-folder" { return 0.100 }
            if operation == "delete-middle" || operation == "rename-middle" { return 0.060 }
        }
        // B との比と K5 の比は、交互の実測の中央値から判定する。
        return nil
    }
}
