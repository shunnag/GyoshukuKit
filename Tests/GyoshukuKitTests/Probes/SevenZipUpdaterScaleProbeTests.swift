import Foundation
import Darwin
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScale() throws {
        let fixtureRoot = try OptInGate.path("GYOSHUKU_7Z_SCALE_DIR")
        let root = try TestSupport.directory("7z-scale")
        let selected = OptInGate.value("GYOSHUKU_7Z_SCALE_CASE")
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        let cases: [(String, [String])] = [("g_real", ["rename", "last", "add", "first", "middle"]),
            ("g_k100", ["rename", "first"]), ("z_k100", ["rename", "first"]), ("z_real_default", ["rename", "first"])]
        ScaleProbe.report(tag: "7Z-SCALE-PROCESS", columns: ["pid=\(ProcessInfo.processInfo.processIdentifier)", "outputs=\(root.path)"])
        ScaleProbe.report(tag: "7Z-SCALE", columns: ["fixture", "operation", "engine", "repeat", "open_ms", "mutate_ms", "commit_ms",
            "plan_ms", "password_ms", "scratch_encode_ms", "scratch_copy_ms", "packs_ms", "header_ms", "V1_ms", "V2_ms", "V3_ms",
            "V3a_ms", "output_bytes", "load1", "load5", "load15"])
        func measure(_ source: URL, fixture: String, operations: [String], password: String? = nil) throws {
            let reader = try SevenZipEditSupport.reader(source, password: password)
            let files = reader.entries.filter { $0.kind == .file && ($0.uncompressedSize ?? 0) > 0 }.map(\.index)
            let inputSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! NSNumber
            for operation in operations {
                if let selected, selected != "\(fixture)/\(operation)" { continue }
                for rewrite in [false, true] {
                    var commits: [Double] = [], opens: [Double] = []
                    for repeatIndex in 0..<5 {
                        let output = root.appendingPathComponent("\(fixture)-\(operation)-\(rewrite)-\(repeatIndex).7z")
                        var loads = [Double](repeating: 0, count: 3); _ = getloadavg(&loads, 3)
                        let crypto = ["set", "change", "remove"].contains(operation)
                        let target: String? = crypto ? (operation == "remove" ? nil : "updated") : password
                        let options = WriterOptions(password: target)
                        let start = now()
                        let editor: any ArchiveEditing = try rewrite
                            ? ArchiveRewriter.open(url: source, password: password, output: output, format: .sevenZip, options: options)
                            : SevenZipUpdater.open(url: source, password: password, output: output, options: options)
                        let opened = now()
                        switch operation {
                        case "first": try editor.remove(entriesAt: [files[0]])
                        case "last": try editor.remove(entriesAt: [files.last!])
                        case "middle": try editor.remove(entriesAt: [files[files.count / 2]])
                        case "add": try editor.add(data: Data(repeating: 42, count: 1024), as: "probe-added", modificationDate: TestSupport.date, permissions: nil)
                        case "set", "change", "remove": try (editor as? any ArchiveReencrypting)?.reencryptExistingEntries(currentPassword: password)
                        default: try editor.rename(entryAt: files[files.count / 2], to: "probe-renamed.txt")
                        }
                        let mutated = now()
                        try editor.commit()
                        let ended = now()
                        let stats = (editor as? SevenZipUpdater)?.lastCommitStatistics ?? SevenZipCommitStatistics()
                        let outputSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! NSNumber
                        let values = [(opened - start) * 1000, (mutated - opened) * 1000, (ended - mutated) * 1000,
                            stats.planSeconds * 1000, stats.passwordVerificationSeconds * 1000,
                            stats.reencodeScratchSeconds * 1000, stats.scratchCopySeconds * 1000,
                            stats.packsSeconds * 1000, stats.headerSeconds * 1000, stats.v1Seconds * 1000,
                            stats.v2Seconds * 1000, stats.v3Seconds * 1000, stats.v3aSeconds * 1000]
                        ScaleProbe.report(tag: "7Z-SCALE", columns: [fixture, operation, rewrite ? "rewriter" : "updater", "\(repeatIndex)"]
                            + values.map { String(format: "%.3f", $0) } + ["\(outputSize)"] + loads.map { String(format: "%.2f", $0) })
                        opens.append(values[0]); commits.append(values[2])
                        if !rewrite && fixture == "z_k100" && operation == "rename" {
                            XCTAssertLessThanOrEqual(outputSize.doubleValue, inputSize.doubleValue * 1.1)
                        }
                        if repeatIndex != 4 { try FileManager.default.removeItem(at: output) }
                    }
                    ScaleProbe.report(tag: "7Z-SCALE-MEDIAN", columns: [fixture, operation, rewrite ? "rewriter" : "updater",
                        String(format: "open_ms=%.3f", opens.sorted()[2]), String(format: "commit_ms=%.3f", commits.sorted()[2])])
                    if !rewrite {
                        let limit: Double? = fixture == "g_real" ? (["first", "middle"].contains(operation) ? 100 : 50)
                            : fixture == "g_k100" ? 600 : fixture == "z_k100" ? (operation == "rename" ? 800 : 3000)
                            : fixture == "z_real_default" ? (operation == "rename" ? 100 : nil) : 1500
                        if let limit, !ScaleProbe.threshold(commits.sorted()[2], limit: limit, "\(fixture) \(operation) median commit_ms") {
                            ScaleProbe.report(tag: "7Z-SCALE-MISS", columns: [fixture, operation, "commit_limit_ms=\(limit)"])
                        }
                        if fixture == "g_k100", !ScaleProbe.threshold(opens.sorted()[2], limit: 700, "g_k100 \(operation) median open_ms") {
                            ScaleProbe.report(tag: "7Z-SCALE-MISS", columns: ["g_k100", "open_limit_ms=700"])
                        }
                    }
                }
            }
        }
        for (fixture, operations) in cases { try measure(fixtureRoot.appendingPathComponent(fixture + ".7z"), fixture: fixture, operations: operations) }
        for encrypted in [false, true] {
            if let selected, !selected.hasPrefix(encrypted ? "aes256/" : "plain256/") { continue }
            let source = root.appendingPathComponent("payload-\(encrypted).7z")
            let writer = try ArchiveWriter.create(url: source, format: .sevenZip,
                options: WriterOptions(password: encrypted ? "original" : nil))
            for index in 0..<64 {
                let data = try SevenZipProbePayload.data(file: index, size: 4 * 1024 * 1024)
                try writer.add(data: data, as: String(format: "payload/p%07d.txt", index), modificationDate: TestSupport.date)
            }
            for index in 0..<1000 { try writer.add(data: Data([42]), as: String(format: "d%03d/s%d/f%07d.txt", index / 1000, (index / 100) % 10, index), modificationDate: TestSupport.date) }
            try writer.finish()
            try measure(source, fixture: encrypted ? "aes256" : "plain256", operations: encrypted ? ["change", "remove"] : ["set"], password: encrypted ? "original" : nil)
        }
    }
}
