import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterTests: XCTestCase {
    func testOperationOrderBytesStrategiesAndOwnersInBothModes() throws {
        for sequential in [false, true] {
            try TarUpdater.$testingDisablesClone.withValue(sequential) {
                for operation in 0..<9 {
                    let root = try TestSupport.directory("p2-edit-\(sequential)-\(operation)")
                    let source = try TarP2Support.fixture(root)
                    let before = try Data(contentsOf: source)
                    let (layout, _, old) = try TarP2Support.scan(source)
                    let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.tar")
                    let updater = try TarUpdater.open(url: source, output: output)
                    var expected = old.entries.map(\.name)
                    var changed: Set<Int> = []
                    if operation == 5 || operation == 6 { try updater.add(data: Data([33]), as: "added", modificationDate: TestSupport.date) }
                    switch operation {
                    case 0: break
                    case 1: try updater.remove(entriesAt: [5, 5]); expected.removeLast(); changed = [5]
                    case 2: try updater.rename(entryAt: 2, to: "edit-000002"); expected[2] = "edit-000002"; changed = [2]
                    case 3, 5:
                        try updater.remove(entriesAt: [2]); expected.remove(at: 2); changed = [2]
                    case 4: try updater.rename(entryAt: 2, to: String(repeating: "名前", count: 65)); expected[2] = String(repeating: "名前", count: 65); changed = [2]
                    case 6: try updater.rename(entryAt: 2, to: "edit-000002"); expected[2] = "edit-000002"; changed = [2]
                    case 7: try updater.remove(entriesAt: Array(0..<6)); expected = []; changed = Set(0..<6)
                    default: try updater.rename(entryAt: 2, to: old.entries[2].name)
                    }
                    if operation == 5 || operation == 6 { expected.append("added") }
                    if operation == 7 { try updater.addDirectory("new", modificationDate: TestSupport.date, ownerIDs: .init(user: 501, group: 20)); expected.append("new/") }
                    let writes = ZipIOEvents(), reads = ZipIOEvents()
                    var progress: [ArchiveUpdater.CommitProgress] = []
                    try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                        try SplicedArchiveOutput.$verificationReadObserver.withValue(reads.write) {
                            try updater.commit { progress.append($0) }
                        }
                    }
                    XCTAssertEqual(progress.first?.completedBytes, 0)
                    XCTAssertEqual(progress.last?.totalBytes, writes.bytes + reads.bytes)
                    XCTAssertEqual(progress.last?.completedBytes, progress.last?.totalBytes)
                    XCTAssertEqual(Set(progress.map(\.totalBytes)).count, 1)
                    XCTAssertEqual(progress.map(\.completedBytes), progress.map(\.completedBytes).sorted())
                    let outputInfo = try ZipP1Support.info(output)
                    for fd: Int32 in 0..<256 {
                        var opened = stat()
                        if fstat(fd, &opened) == 0 {
                            XCTAssertFalse(opened.st_dev == outputInfo.st_dev && opened.st_ino == outputInfo.st_ino, "output descriptor \(fd) is still open")
                        }
                    }
                    let (after, _, reader) = try TarP2Support.scan(output)
                    XCTAssertEqual(reader.entries.map(\.name), expected)
                    let bytes = try Data(contentsOf: output)
                    for entry in old.entries where !changed.contains(entry.index) {
                        let newIndex = try XCTUnwrap(reader.entries.firstIndex { $0.name == entry.name })
                        let a = layout.member(entry.index), b = after.member(newIndex)
                        XCTAssertEqual(before.subdata(in: Int(a.groupStart)..<Int(a.paddedEnd)), bytes.subdata(in: Int(b.groupStart)..<Int(b.paddedEnd)))
                        XCTAssertEqual(try old.read(entry), try reader.read(reader.entries[newIndex]))
                    }
                    XCTAssertEqual(try Data(contentsOf: source), before)
                    XCTAssertEqual(try ZipP1Support.info(output).st_mode & 0o777, 0o600)
                    XCTAssertEqual(try ZipP1Support.info(output).st_flags, 0)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["out.tar"])
                    if operation == 0 || operation == 8 {
                        XCTAssertEqual(bytes, before)
                        XCTAssertEqual(updater.lastCommitStrategy, .unchanged)
                    } else {
                        XCTAssertEqual(bytes.count % 10240, 0)
                        XCTAssertTrue(bytes[Int(after.membersEnd)...].allSatisfy { $0 == 0 })
                        let strategy: TarUpdater.CommitStrategy = operation == 5 || (operation == 6 && sequential) ? .relocatedAppend
                            : sequential ? .sequential : [1, 2].contains(operation) ? .inPlacePatch : .splice
                        XCTAssertEqual(updater.lastCommitStrategy, strategy)
                    }
                    try updater.commit()
                    XCTAssertThrowsError(try updater.addDirectory("late"))
                }
            }
        }
    }

    func testRawNamesRootCommentTrailingBytesAndEmptyArchives() throws {
        let root = try TestSupport.directory("p2-raw")
        let comment = TarP2Support.extensionBytes(0x67, TarRecords.paxRecord("comment", value: Data(String(repeating: "a", count: 40).utf8)))
        for (index, names) in [[String](), ["./", "./a", "/b", "double//c", "cafe\u{301}"]].enumerated() {
            for tailSize in [512, 1024, 10240] {
                let source = root.appendingPathComponent("source-\(index)-\(tailSize).tar")
                try TarP2Support.archive(names.map { (TarRecords.Entry(name: Data($0.utf8), type: $0 == "./" ? 0x35 : 0x30), Data()) },
                                         at: source, prefix: comment, tail: Data(count: tailSize) + Data("TAIL".utf8))
                let before = try Data(contentsOf: source)
                let unchanged = root.appendingPathComponent("unchanged-\(index)-\(tailSize).tar")
                try TarUpdater.open(url: source, output: unchanged).commit()
                XCTAssertEqual(try Data(contentsOf: unchanged), before)
                let output = root.appendingPathComponent("out-\(index)-\(tailSize).tar")
                let updater = try TarUpdater.open(url: source, output: output)
                try updater.add(data: Data(), as: "new", modificationDate: TestSupport.date)
                try updater.commit()
                let bytes = try Data(contentsOf: output)
                let (layout, _, reader) = try TarP2Support.scan(source)
                XCTAssertEqual(bytes.prefix(Int(layout.membersEnd)), before.prefix(Int(layout.membersEnd)))
                XCTAssertEqual(try ArchiveReader.open(url: output).entries.map(\.rawName.bytes), reader.entries.map(\.rawName.bytes) + [Array("new".utf8)])
                XCTAssertNil(bytes.range(of: Data("TAIL".utf8)))
            }
        }
        for size in [1024, 10240] {
            let source = root.appendingPathComponent("zero-\(size).tar")
            try Data(count: size).write(to: source)
            let updater = try TarUpdater.open(url: source, output: root.appendingPathComponent("added-\(size).tar"))
            try updater.addDirectory("first")
            try updater.commit()
        }
    }

    func testWrittenAndCopiedBytes500Members() throws {
        let root = try TestSupport.directory("p2-io")
        let source = try TarP2Support.fixture(root, count: 500, size: 64 * 1024)
        let (layout, _, _) = try TarP2Support.scan(source)
        for operation in 0..<4 {
            let output = root.appendingPathComponent("out-\(operation).tar")
            let updater = try TarUpdater.open(url: source, output: output)
            if operation == 0 { try updater.remove(entriesAt: [499]) }
            if operation == 1 { try updater.rename(entryAt: 250, to: "edit-000250") }
            if operation == 2 { try updater.add(data: Data([1]), as: "new") }
            if operation == 3 { try updater.remove(entriesAt: [250]) }
            let writes = ZipIOEvents(), reads = ZipIOEvents()
            try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                try ZipUpdateSource.$readObserver.withValue(reads.read) { try updater.commit() }
            }
            if operation == 0 || operation == 2 { XCTAssertLessThanOrEqual(writes.bytes, 11264); XCTAssertEqual(reads.bytes, 0) }
            if operation == 1 {
                XCTAssertLessThanOrEqual(writes.bytes, 512 + 11264)
                XCTAssertTrue(reads.events.allSatisfy { $0.offset >= layout.member(250).groupStart && $0.offset + UInt64($0.count) <= layout.member(250).dataStart })
            }
            if operation == 3 {
                let moved = layout.membersEnd - layout.member(251).groupStart
                let (result, _, _) = try TarP2Support.scan(output)
                XCTAssertEqual(reads.bytes, moved)
                XCTAssertEqual(writes.bytes, moved + (try ZipUpdateSource(url: output)).length - result.membersEnd)
            }
        }
    }
}
