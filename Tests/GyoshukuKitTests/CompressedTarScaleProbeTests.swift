import Foundation
import Darwin
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarScaleProbeTests: XCTestCase {
    func testMixedNewAndOldLayouts() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_SCALE_PROBES"] == "1",
              let corpusPath = ProcessInfo.processInfo.environment["GYOSHUKU_SCALE_CORPUS"] else {
            throw XCTSkip("Set GYOSHUKU_SCALE_PROBES=1 and GYOSHUKU_SCALE_CORPUS to p3val")
        }
        let corpus = URL(fileURLWithPath: corpusPath).appendingPathComponent("arc")
        let root = try TestSupport.directory("p3-scale")
        let raw = corpus.appendingPathComponent("mixed.tar")
        let options = WriterOptions(compressionThreads: 8)
        // 合計 3 分待っても下がらない負荷は、そのまま記録し、時間の閾値は変えない。
        var loadWaitBudget = 180
        TestSupport.report("TAR-SCALE layout\tcodec\toperation\tstage\twall_ms\tplan_ms\tencode_worker_ms\tcopy_ms\tselfcheck_ms\treencoded_bytes\treencoded_old_bytes\tcarried_bytes\tcarried_chunks\tencoded_chunks\tscratch_bytes\toutput_bytes\tload1\tload5\tload15\tlimit_ms\tload_wait_s")
        for format in CompressedTarTestSupport.formats {
            let suffix = format == .tarGzip ? "tgz" : format == .tarBzip2 ? "tbz" : "txz"
            let fresh: URL
            if let directory = ProcessInfo.processInfo.environment["GYOSHUKU_SCALE_NEW_ARCHIVES"] {
                fresh = URL(fileURLWithPath: directory).appendingPathComponent("mixed-8.\(suffix)")
            } else {
                fresh = root.appendingPathComponent("fresh.\(suffix)")
                let writer = try ArchiveRewriter.open(url: raw, output: fresh, format: format, options: options)
                try writer.commit()
            }
            try CompressedTarTestSupport.imagesEqual(CompressedTarTestSupport.open(fresh).tarEditingSnapshot()!.image, FileByteSource(url: raw))
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
                    var load = [Double](repeating: 0, count: 3)
                    _ = getloadavg(&load, 3)
                    var waited = 0
                    while load[0] > 4, loadWaitBudget > 0 {
                        try Task.checkCancellation()
                        Thread.sleep(forTimeInterval: 1)
                        waited += 1; loadWaitBudget -= 1
                        _ = getloadavg(&load, 3)
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = try updater.commit(progress: nil)
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let statistics = try XCTUnwrap(updater.lastCommitStatistics)
                    let verifyStart = ProcessInfo.processInfo.systemUptime
                    let verified = try CompressedTarTestSupport.k5(output, base: base, result: result)
                    let k5 = ProcessInfo.processInfo.systemUptime - verifyStart
                    let limit: Double
                    if format == .tarGzip { limit = layout == "new" ? 0.6 : 0.9 }
                    else if format == .tarBzip2 { limit = layout == "new" ? 1.2 : 1.8 }
                    else if operation == "append" || operation == "rename-text256" { limit = layout == "new" ? 1.0 : .infinity }
                    else { limit = layout == "new" ? 1.5 : .infinity }
                    let stats = [statistics.planningSeconds, statistics.encodingSeconds, statistics.copyingSeconds, statistics.selfCheckSeconds]
                        .map { String(format: "%.3f", $0 * 1000) }.joined(separator: "\t")
                    let bytes = [result.reencodedImageBytes, result.reencodedOldImageBytes, result.carriedCompressedBytes]
                        .map(String.init).joined(separator: "\t")
                    let counts = "\(statistics.carriedChunks)\t\(statistics.reencodedChunks)\t\(statistics.scratchBytes)\t\(result.output.size)"
                    let loads = load.map { String(format: "%.2f", $0) }.joined(separator: "\t")
                    for (stage, seconds) in [("commit", elapsed), ("k5", k5)] {
                        TestSupport.report("TAR-SCALE \(layout)\t\(suffix)\t\(operation)\t\(stage)\t" + String(format: "%.3f", seconds * 1000)
                            + "\t" + stats + "\t" + bytes + "\t" + counts + "\t" + loads + "\t" + String(format: "%.3f", limit * 1000) + "\t\(waited)")
                    }
                    XCTAssertLessThanOrEqual(elapsed, limit, "\(layout) \(suffix) \(operation), load \(load)")
                    XCTAssertLessThanOrEqual(statistics.scratchBytes, UInt64((operation == "append" ? 4096 : 0) + 1048576))
                    if layout == "new", operation == "append" { XCTAssertEqual(result.reencodedOldImageBytes, 0) }
                    let full = try CompressedTarTestSupport.open(output)
                    XCTAssertEqual(verified.entries.map(\.name), full.entries.map(\.name))
                    try CompressedTarTestSupport.imagesEqual(verified.tarEditingSnapshot()!.image, full.tarEditingSnapshot()!.image)
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }
}


extension CompressedTarScaleProbeTests {
    func testXZPackingArchives() throws {
        guard let path = ProcessInfo.processInfo.environment["GYOSHUKU_P14_ARCHIVES"] else {
            throw XCTSkip("Set GYOSHUKU_P14_ARCHIVES to the mixed, payload and mid archives")
        }
        let assertsTime = ProcessInfo.processInfo.environment["GYOSHUKU_P14_ASSERT"] == "1"
        let archives = URL(fileURLWithPath: path)
        let root = try TestSupport.directory("p14-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        let options = WriterOptions(compressionThreads: 8)
        var loadWaitBudget = 180, sequence = 0
        TestSupport.report("TAR-P14 archive\toperation\tcommit_ms\tk5_ms\topen_ms\tstrategy\treencoded_bytes\treencoded_old_bytes\tcarried_bytes\tcarried_chunks\treencoded_chunks\tencodingSeconds\tselfCheckSeconds\tload1\tload5\tload15\tload_wait_s")

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
            var load = [Double](repeating: 0, count: 3), waited = 0
            _ = getloadavg(&load, 3)
            while load[0] > 4, loadWaitBudget > 0 {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 1)
                waited += 1; loadWaitBudget -= 1
                _ = getloadavg(&load, 3)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try updater.commit(progress: nil)
            let commit = ProcessInfo.processInfo.systemUptime - started
            let statistics = try XCTUnwrap(updater.lastCommitStatistics)
            let k5Start = ProcessInfo.processInfo.systemUptime
            let verified = try CompressedTarTestSupport.k5(output, base: base, result: result)
            let k5 = ProcessInfo.processInfo.systemUptime - k5Start
            let openStart = ProcessInfo.processInfo.systemUptime
            let full = try CompressedTarTestSupport.open(output)
            let open = ProcessInfo.processInfo.systemUptime - openStart
            XCTAssertEqual(verified.entries.map(\.name), full.entries.map(\.name))
            XCTAssertEqual(verified.entries.map(\.kind), full.entries.map(\.kind))
            let times = [commit, k5, open].map { String(format: "%.3f", $0 * 1000) }.joined(separator: "\t")
            let bytes = [result.reencodedImageBytes, result.reencodedOldImageBytes, result.carriedCompressedBytes]
                .map(String.init).joined(separator: "\t")
            let counts = "\(statistics.carriedChunks)\t\(statistics.reencodedChunks)"
            let seconds = [statistics.encodingSeconds, statistics.selfCheckSeconds].map { String(format: "%.6f", $0) }.joined(separator: "\t")
            let loads = load.map { String(format: "%.2f", $0) }.joined(separator: "\t")
            TestSupport.report("TAR-P14 \(name)\t\(operation)\t" + times + "\t\(result.strategy)\t" + bytes
                + "\t" + counts + "\t" + seconds + "\t" + loads + "\t\(waited)")
            if assertsTime, let limit = Self.p14CommitLimit(name: name, operation: operation) {
                XCTAssertLessThanOrEqual(commit, limit, "\(name) \(operation), load \(load)")
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

    private static func p14CommitLimit(name: String, operation: String) -> Double? {
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
