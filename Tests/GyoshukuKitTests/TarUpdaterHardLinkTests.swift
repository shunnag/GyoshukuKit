import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterHardLinkTests: XCTestCase {
    func testRetargetMaterializeRenameAndMetadata() throws {
        for removed in [Set([0]), Set([1]), Set([0, 1]), Set<Int>()] {
            for rename in [false, true] {
                let root = try TestSupport.directory("p2-links-\(removed.sorted())-\(rename)")
                let source = root.appendingPathComponent("source.tar")
                let data = Data("payload".utf8)
                let d = TarRecords.Entry(name: Data("data".utf8), size: UInt64(data.count))
                let l1 = TarRecords.Entry(name: Data("link1".utf8), mode: 0o600, mtime: 1234, uid: 501, gid: 20, type: 0x31, link: Data("data".utf8))
                let l2 = TarRecords.Entry(name: Data("link2".utf8), type: 0x31, link: Data("link1".utf8))
                try TarP2Support.archive([(d, data), (l1, Data()), (l2, Data())], at: source)
                let output = root.appendingPathComponent("out.tar")
                let updater = try TarUpdater.open(url: source, output: output)
                try updater.remove(entriesAt: Array(removed))
                if rename { try updater.rename(entryAt: removed.contains(0) ? (removed.contains(1) ? 2 : 1) : 0, to: "親/" + String(repeating: "長", count: 70)) }
                try updater.commit()
                let (layout, bytes, reader) = try TarP2Support.scan(output)
                for entry in reader.entries {
                    var target = entry.index
                    while let text = reader.entries[target].formatSpecific["hardLinkTargetIndex"], let index = Int(text) { target = index }
                    XCTAssertEqual(try reader.read(reader.entries[target]), data)
                }
                XCTAssertEqual(reader.entries[0].kind, .file)
                if reader.entries.count > 1 {
                    XCTAssertEqual(reader.entries[1].kind, .hardlink)
                    XCTAssertEqual(reader.entries[1].formatSpecific["hardLinkTargetIndex"], "0")
                    XCTAssertEqual(reader.entries[1].formatSpecific["linkPath"], reader.entries[0].name)
                }
                if removed == [0] {
                    XCTAssertEqual(reader.entries[0].posixPermissions, 0o600)
                    XCTAssertEqual(reader.entries[0].formatSpecific["uid"], "501")
                    XCTAssertEqual(try bytes.bytes(at: layout.member(0).headerStart + 157, count: 100), Data(count: 100))
                }
                let extracted = root.appendingPathComponent("extract")
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
                try TestSupport.run(ReferenceTool.bsdtar, ["-xf", output.path, "-C", extracted.path], in: root, log: "extract")
                let inodes = try reader.entries.map { try ZipP1Support.info(extracted.appendingPathComponent($0.name)).st_ino }
                XCTAssertEqual(Set(inodes).count, 1)
            }
        }
    }
}
