import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterDifferentialTests: XCTestCase {
    func testFixedSeedModelAndRewriter300Sequences() throws {
        let iterations = OptInGate.integer("GYOSHUKU_LHA_DIFF_ITERATIONS", default: 300)
        var random: UInt64 = 0x20260926
        func next(_ limit: Int) -> Int { random = random &* 6364136223846793005 &+ 1442695040888963407; return Int((random >> 32) % UInt64(limit)) }
        struct Item { let name: String; let data: Data; let directory: Bool }
        let root = try TestSupport.directory("lha-differential")
        for trial in 0..<iterations {
            let work = try TestSupport.work(in: root)
            defer { try? FileManager.default.removeItem(at: work) }
            let source = work.appendingPathComponent("source.lzh")
            let items = (0..<(10 + next(291))).map { index -> Item in
                let directory = index % 13 == 0
                return Item(name: (index % 9 == 0 ? "日本-" : "item-") + String(index) + (directory ? "/" : ""),
                            data: directory ? Data() : Data(repeating: UInt8(next(256)), count: next(80)), directory: directory)
            }
            if trial % 2 == 0 {
                let writer = try ArchiveWriter.create(url: source, format: .lha, options: .init(compressionThreads: 1))
                for item in items {
                    if item.directory { try writer.addDirectory(item.name) }
                    else { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                }
                try writer.finish()
            } else {
                var data = Data()
                for (index, item) in items.enumerated() { data += LHAHeaderBuilder.member(level: UInt8(index % 3), name: item.name, data: item.data, directory: item.directory) }
                try (data + Data([0])).write(to: source)
            }
            let output = work.appendingPathComponent("out.lzh"), rewrite = work.appendingPathComponent("rewrite.lzh")
            let updater = try LHAUpdater.open(url: source, output: output, options: .init(compressionThreads: 1))
            let rewriter = try ArchiveRewriter.open(url: source, output: rewrite, format: .lha, options: .init(compressionThreads: 1))
            let editors: [any ArchiveEditing] = [updater, rewriter]
            let removed = Set((0..<(1 + next(5))).map { _ in next(items.count) })
            var renamed = [Int: String]()
            for index in (0..<3).map({ _ in next(items.count) }) where !removed.contains(index) {
                renamed[index] = "改名-\(index)-\(trial)" + (items[index].directory ? "/" : "")
            }
            let additions = (0..<(1 + next(4))).map { Item(name: "added-\($0)", data: Data(repeating: UInt8(next(256)), count: next(64)), directory: false) }
            func add(_ item: Item) throws { for editor in editors { try editor.add(data: item.data, as: item.name, modificationDate: TestSupport.date, permissions: nil) } }
            let early = trial % 3
            if early > 0 { try add(additions[0]) }
            for editor in editors { try editor.remove(entriesAt: Array(removed)) }
            if early == 2, let first = renamed.keys.sorted().first { for editor in editors { try editor.rename(entryAt: first, to: renamed[first]!) } }
            for item in additions.dropFirst(early > 0 ? 1 : 0) { try add(item) }
            for (index, name) in renamed { for editor in editors { try editor.rename(entryAt: index, to: name) } }
            for editor in editors { try editor.commit() }
            let expected = items.enumerated().filter { !removed.contains($0.offset) }.map { Item(name: renamed[$0.offset] ?? $0.element.name, data: $0.element.data, directory: $0.element.directory) } + additions
            let old = try LHAUpdateSupport.scan(source), new = try LHAUpdateSupport.scan(output)
            try LHAUpdateSupport.unchanged(old, new, indices: items.indices.filter { !removed.contains($0) && renamed[$0] == nil })
            for url in [output, rewrite] {
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(reader.entries.map(\.name), expected.map(\.name), "trial \(trial)")
                for (entry, item) in zip(reader.entries, expected) {
                    XCTAssertEqual(entry.kind, item.directory ? .directory : .file, "trial \(trial)")
                    XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), "trial \(trial)")
                    XCTAssertEqual(try reader.read(entry), item.data, "trial \(trial) \(entry.name)")
                }
            }
        }
        print("LHA-DIFF\tseed=0x20260926\titerations=\(iterations)")
    }
}
