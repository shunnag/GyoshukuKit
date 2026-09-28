import Foundation
import Darwin
import Synchronization
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterOracleTests: XCTestCase {
    func testPrototypeIntendedImages() throws {
        let oracle = try OptInGate.path("GYOSHUKU_TAR_ORACLE_DIR")
        let root = try TestSupport.directory("tar-oracle")
        var count = 0
        for corpus in ["headers", "small", "text", "mixed"] {
            let source = oracle.appendingPathComponent("arc/\(corpus).tar")
            let (layout, _, reader) = try TarEditTestSupport.scan(source)
            let files = reader.entries.filter { $0.formatSpecific["typeFlag"] == "0" }
            for edit in ["append", "delete-mid", "delete-big", "delete-huge", "rename-same", "rename-diff"] {
                let intended = oracle.appendingPathComponent("out/\(corpus)-\(edit).intended.tar")
                guard FileManager.default.fileExists(atPath: intended.path) else { continue }
                let output = root.appendingPathComponent("\(corpus)-\(edit).tar")
                let updater = try TarUpdater.open(url: source, output: output)
                if edit == "append" {
                    let (_, _, expected) = try TarEditTestSupport.scan(intended)
                    for entry in expected.entries.suffix(3) {
                        try updater.add(data: expected.read(entry), as: entry.name,
                                        modificationDate: Date(timeIntervalSince1970: 1700000000), permissions: 0o644)
                    }
                } else if edit.hasPrefix("delete") {
                    let member: ArchiveEntry
                    if edit == "delete-mid" { member = files[files.count / 2] }
                    else if edit == "delete-huge" { member = try XCTUnwrap(files.first { $0.name == "text256.txt" }) }
                    else if corpus == "mixed" { member = try XCTUnwrap(files.first { $0.name == "rand20.bin" }) }
                    else {
                        member = try XCTUnwrap(files.max {
                            let a = layout.member($0.index), b = layout.member($1.index)
                            return a.paddedEnd - a.groupStart < b.paddedEnd - b.groupStart
                        })
                    }
                    try updater.remove(entriesAt: [member.index])
                } else {
                    let member = files[edit == "rename-same" ? files.count / 3 : 2 * files.count / 3]
                    let components = member.name.split(separator: "/", omittingEmptySubsequences: false)
                    let parent = components.dropLast().joined(separator: "/")
                    let prefix = edit == "rename-same" ? "renamed-" : "renamed-with-a-long-leaf-name-that-does-not-fit-the-ustar-name-field-" + String(repeating: "z", count: 60) + "-"
                    var name = (parent.isEmpty ? "" : parent + "/") + prefix + components.last!
                    // headers の保存済み神託は、現行 script の 60 個より前の 20 個の z を使う。
                    if corpus == "headers", edit == "rename-diff" {
                        let (_, _, frozen) = try TarEditTestSupport.scan(intended)
                        let historical = name.replacingOccurrences(of: String(repeating: "z", count: 60), with: String(repeating: "z", count: 20))
                        XCTAssertEqual(frozen.entries[member.index].name, historical)
                        name = historical
                    }
                    try updater.rename(entryAt: member.index, to: name)
                }
                try updater.commit()
                let (result, bytes, _) = try TarEditTestSupport.scan(output)
                let golden = try ZipUpdateSource(url: intended)
                let whole = edit == "append" || edit == "rename-same"
                let length = whole ? golden.length : result.membersEnd
                if whole { XCTAssertEqual(bytes.length, golden.length) }
                var offset: UInt64 = 0
                while offset < length {
                    let size = Int(min(4 * 1024 * 1024, length - offset))
                    XCTAssertEqual(try bytes.bytes(at: offset, count: size), try golden.bytes(at: offset, count: size), "\(corpus)-\(edit) at \(offset)")
                    offset += UInt64(size)
                }
                let tail = try bytes.bytes(at: result.membersEnd, count: Int(bytes.length - result.membersEnd))
                XCTAssertGreaterThanOrEqual(tail.count, 1024)
                XCTAssertTrue(tail.allSatisfy { $0 == 0 })
                XCTAssertEqual(bytes.length % 10240, 0)
                TestSupport.report("TAR-ORACLE \(corpus)-\(edit) bytes=\(bytes.length) equal=\(whole ? "whole" : "members")")
                count += 1
            }
        }
        XCTAssertEqual(count, 18)
    }
}
