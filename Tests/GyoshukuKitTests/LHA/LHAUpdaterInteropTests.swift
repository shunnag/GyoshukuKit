import Foundation
import CryptoKit
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterInteropTests: XCTestCase {
    func testLhasa() throws { try compare(tool: ReferenceTool.lhasa) }
    func testSevenZip() throws { try compare(tool: ReferenceTool.sevenZip) }
    func testBSDTar() throws { try compare(tool: ReferenceTool.bsdtar) }

    /// `directory` を current directory にして展開させる。log は `files` が数えないよう `work` に置く。
    private func run(_ tool: String, _ arguments: [String], in directory: URL, work: URL, log: String) throws -> ReferenceTool.Output {
        try ReferenceTool.run(tool, arguments, in: work, log: log, expect: .unchecked, stdin: .nullDevice,
                              environment: [:], workingDirectory: directory)
    }
    private func files(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count + 1))] = Data(SHA256.hash(data: try Data(contentsOf: url)))
        }
        return result
    }
    private func compare(tool: String) throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("Missing \(tool)") }
        let root = try TestSupport.directory("lha-interop-" + URL(fileURLWithPath: tool).lastPathComponent)
        let lhasa = tool.hasSuffix("/lha"), seven = tool.hasSuffix("/7zz")
        var comparisons = 0
        for fixture in LHAUpdateSupport.accepted {
            let source = try LHAUpdateSupport.fixture(fixture, in: root)
            let original = try ArchiveReader.open(url: source)
            for operation in ["delete", "rename", "append"] {
                let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.lzh")
                let editor = try LHAUpdater.open(url: source, output: output)
                let target = original.entries.count / 2
                if operation == "delete" { try editor.remove(entriesAt: [target]) }
                if operation == "rename" { try editor.rename(entryAt: target, to: "renamed") }
                if operation == "append" { try editor.add(data: Data("addition".utf8), as: "added", modificationDate: TestSupport.date) }
                try editor.commit()
                let result = try ArchiveReader.open(url: output)
                for reader in [original, result] { for entry in reader.entries { _ = try reader.read(entry) } }
                let oldDirectory = try TestSupport.work(in: work), newDirectory = try TestSupport.work(in: work)
                let oldArgs = lhasa ? ["xf", source.path] : seven ? ["x", "-y", source.path] : ["-xf", source.path]
                let oldExtract = try run(tool, oldArgs, in: oldDirectory, work: work, log: "extract-source")
                if oldExtract.status != 0 {
                    print("LHA-INTEROP-EXCLUDED\t\(tool)\t\(fixture)\tbaseline exit=\(oldExtract.status)")
                    continue
                }
                let newExtract = try run(tool, lhasa ? ["xf", output.path] : seven ? ["x", "-y", output.path] : ["-xf", output.path],
                                         in: newDirectory, work: work, log: "extract-output")
                if result.entries.isEmpty {
                    // 7zz/bsdtar は GK の新規空 LHA も認識しない。規定の [0] と同じ扱いを確認する。
                    XCTAssertEqual(try Data(contentsOf: output), Data([0]))
                    let baseline = work.appendingPathComponent("empty.lzh")
                    let writer = try ArchiveWriter.create(url: baseline, format: .lha); try writer.finish()
                    let baselineDirectory = try TestSupport.work(in: work)
                    let baselineResult = try run(tool, lhasa ? ["xf", baseline.path] : seven ? ["x", "-y", baseline.path] : ["-xf", baseline.path],
                                                 in: baselineDirectory, work: work, log: "extract-empty")
                    XCTAssertEqual(newExtract.status, baselineResult.status)
                    XCTAssertEqual(try files(newDirectory), [:])
                    print("LHA-INTEROP-EMPTY\t\(tool)\t\(fixture)\texit=\(newExtract.status)")
                    continue
                }
                XCTAssertEqual(newExtract.status, 0, "\(fixture) \(operation): \(newExtract.utf8Text)")
                if lhasa || seven {
                    for url in [source, output] {
                        let checked = try run(tool, [lhasa ? "l" : "t", url.path], in: work, work: work,
                                              log: url == source ? "check-source" : "check-output")
                        let text = checked.utf8Text
                        XCTAssertEqual(checked.status, 0, text)
                        if seven {
                            if url == source && fixture == "tl-S5b" { XCTAssertTrue(text.contains("Warnings"), text) }
                            else { XCTAssertFalse(text.contains("Warnings"), text) }
                        }
                    }
                }
                let before = try files(oldDirectory), after = try files(newDirectory)
                // Match each source entry to the external decoder's original spelling, which may differ for CP932.
                var expected = before
                if operation == "delete" || operation == "rename" {
                    let entry = original.entries[target]
                    if entry.kind == .file {
                        let digest = Data(SHA256.hash(data: try original.read(entry)))
                        let key = before[entry.name] != nil ? entry.name : before.keys.first { before[$0] == digest }
                        if let key {
                            expected.removeValue(forKey: key)
                            if operation == "rename" { expected["renamed"] = digest }
                        }
                    }
                } else { expected["added"] = Data(SHA256.hash(data: Data("addition".utf8))) }
                XCTAssertEqual(after, expected, "\(tool) \(fixture) \(operation)")
                comparisons += 1
            }
        }
        XCTAssertGreaterThan(comparisons, 0)
        print("LHA-INTEROP\t\(tool)\tcomparisons=\(comparisons)")
    }
}
