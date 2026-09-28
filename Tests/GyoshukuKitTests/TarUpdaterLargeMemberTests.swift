import Foundation
import Darwin
import Synchronization
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterLargeMemberTests: XCTestCase {
    func testSparseNineGiBOffsetsAndHardLinkMaterialization() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_TAR_LARGE"] == "1" else { throw XCTSkip("GYOSHUKU_TAR_LARGE is not set") }
        let root = try TestSupport.directory("p2-nine-gib")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.tar")
        let size: UInt64 = 9 * 1024 * 1024 * 1024
        let header = TarRecords.Entry(name: Data("huge".utf8), size: size).headers()
        FileManager.default.createFile(atPath: source.path, contents: header)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(header.count) + size)
        try file.seekToEnd()
        try file.write(contentsOf: TarRecords.Entry(name: Data("after".utf8)).headers())
        try file.write(contentsOf: TarRecords.Entry(name: Data("link".utf8), type: 0x31, link: Data("huge".utf8)).headers())
        try file.write(contentsOf: Data(count: 1024))
        try file.close()
        let (layout, _, _) = try TarP2Support.scan(source)
        XCTAssertEqual(layout.member(0).storedSize, size)
        XCTAssertGreaterThan(layout.member(1).groupStart, UInt64(UInt32.max))
        for operation in 0..<4 {
            let output = root.appendingPathComponent("out-\(operation).tar")
            let editor = try TarUpdater.open(url: source, output: output)
            switch operation {
            case 0: try editor.remove(entriesAt: [1])
            case 1: try editor.rename(entryAt: 1, to: "renamed")
            case 2: try editor.add(data: Data([1]), as: "added")
            default: try editor.remove(entriesAt: [0, 1])
            }
            try editor.commit()
            let (result, _, reader) = try TarP2Support.scan(output)
            XCTAssertEqual(result.member(0).storedSize, size)
            XCTAssertEqual(reader.entries[0].kind, .file)
            if operation == 3 { XCTAssertEqual(reader.entries[0].name, "link") }
            try TestSupport.run(ReferenceTool.bsdtar, ["-tvf", output.path], in: root, log: "large-\(operation)")
            try FileManager.default.removeItem(at: output)
        }
    }
}
