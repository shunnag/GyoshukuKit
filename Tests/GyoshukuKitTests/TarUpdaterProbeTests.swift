import Foundation
import Darwin
import Synchronization
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterOracleTests: XCTestCase {
    func testPrototypeIntendedImages() throws {
        guard let directory = ProcessInfo.processInfo.environment["GYOSHUKU_TAR_ORACLE_DIR"] else {
            throw XCTSkip("GYOSHUKU_TAR_ORACLE_DIR is not set")
        }
        let oracle = URL(fileURLWithPath: directory)
        let root = try TestSupport.directory("p2-oracle")
        var count = 0
        for corpus in ["headers", "small", "text", "mixed"] {
            let source = oracle.appendingPathComponent("arc/\(corpus).tar")
            let (layout, _, reader) = try TarP2Support.scan(source)
            let files = reader.entries.filter { $0.formatSpecific["typeFlag"] == "0" }
            for edit in ["append", "delete-mid", "delete-big", "delete-huge", "rename-same", "rename-diff"] {
                let intended = oracle.appendingPathComponent("out/\(corpus)-\(edit).intended.tar")
                guard FileManager.default.fileExists(atPath: intended.path) else { continue }
                let output = root.appendingPathComponent("\(corpus)-\(edit).tar")
                let updater = try TarUpdater.open(url: source, output: output)
                if edit == "append" {
                    let (_, _, expected) = try TarP2Support.scan(intended)
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
                        let (_, _, frozen) = try TarP2Support.scan(intended)
                        let historical = name.replacingOccurrences(of: String(repeating: "z", count: 60), with: String(repeating: "z", count: 20))
                        XCTAssertEqual(frozen.entries[member.index].name, historical)
                        name = historical
                    }
                    try updater.rename(entryAt: member.index, to: name)
                }
                try updater.commit()
                let (result, bytes, _) = try TarP2Support.scan(output)
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

final class TarUpdaterScaleProbeTests: XCTestCase {
    func testReleaseScaleTimingsAndIO() throws {
        guard let text = ProcessInfo.processInfo.environment["GYOSHUKU_TAR_SCALE_ENTRIES"], let count = Int(text), count > 2 else {
            throw XCTSkip("GYOSHUKU_TAR_SCALE_ENTRIES is not set")
        }
        let root = try TestSupport.directory("p2-scale-\(count)")
        let source = try TarP2Support.fixture(root, count: count, size: 1024)
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        TestSupport.report("TAR-SCALE editor\top\tentries\topen_ms\tremove_ms\trename_ms\tadd_ms\tcommit_ms\tverification_ms\tcopy_engine_writes\tverification_reads\toutput_bytes")
        for operation in ["delete-first", "delete-last", "rename-same", "rename-diff", "append", "replace"] {
            for rewrite in [false, true] {
                let output = root.appendingPathComponent("\(operation)-\(rewrite).tar")
                let start = now()
                let editor: any ArchiveEditing = rewrite
                    ? try ArchiveRewriter.open(url: source, output: output, format: .tar)
                    : try TarUpdater.open(url: source, output: output)
                let openTime = now() - start
                var remove = 0.0, rename = 0.0, add = 0.0
                if operation.hasPrefix("delete") || operation == "replace" {
                    let time = now()
                    try editor.remove(entriesAt: [operation == "delete-last" ? count - 1 : operation == "replace" ? count / 2 : 0])
                    remove = now() - time
                }
                if operation.hasPrefix("rename") {
                    let time = now()
                    try editor.rename(entryAt: count / 2, to: operation == "rename-same" ? "edit-000000" : String(repeating: "n", count: 150))
                    rename = now() - time
                }
                if operation == "append" || operation == "replace" {
                    let time = now()
                    try editor.add(data: Data(count: 1024), as: "added", modificationDate: TestSupport.date, permissions: 0o644)
                    add = now() - time
                }
                let writes = ZipIOEvents(), reads = ZipIOEvents(), verification = Mutex(0.0)
                let time = now()
                try SplicedArchiveOutput.$testingVerificationElapsed.withValue({ elapsed in verification.withLock { $0 = elapsed } }) {
                    try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                        try SplicedArchiveOutput.$verificationReadObserver.withValue(reads.write) { try editor.commit() }
                    }
                }
                let commit = now() - time
                let values = [openTime, remove, rename, add, commit, verification.withLock { $0 }].map { String(format: "%.3f", $0 * 1000) }
                TestSupport.report("TAR-SCALE \(rewrite ? "rewriter" : "updater")\t\(operation)\t\(count)\t" + values.joined(separator: "\t") + "\t\(writes.bytes)\t\(reads.bytes)\t\(try ZipUpdateSource(url: output).length)")
                try FileManager.default.removeItem(at: output)
            }
        }
    }
}

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
