import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class LHAUpdaterTests: XCTestCase {
    func testOperationsBytesStrategiesAndProgressInBothModes() throws {
        for sequential in [false, true] {
            try LHAUpdater.$testingDisablesClone.withValue(sequential) {
                for operation in 0..<13 {
                    let root = try TestSupport.directory("lha-edit-\(sequential)-\(operation)")
                    let source = try LHAUpdateSupport.generated(root)
                    let before = try Data(contentsOf: source), info = try ZipEditTestSupport.info(source)
                    let old = try LHAUpdateSupport.scan(source)
                    let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
                    let updater = try LHAUpdater.open(url: source, output: output)
                    var removed = Set<Int>(), renamed = [Int: String]()
                    if operation == 5 || operation == 6 { try updater.add(data: Data([33]), as: "added", modificationDate: TestSupport.date) }
                    switch operation {
                    case 1: removed = [5]
                    case 2, 6: renamed[2] = "edit-000002"
                    case 3, 5: removed = [2]
                    case 4: renamed[2] = "日本/longer-name"
                    case 7: removed = Set(0..<6)
                    case 8: try updater.rename(entryAt: 2, to: old.2.entries[2].name)
                    case 9: removed = [0]
                    case 10: removed = [1, 2, 3]
                    case 11: removed = [0, 2, 5]
                    default: break
                    }
                    try updater.remove(entriesAt: Array(removed) + Array(removed))
                    for (index, name) in renamed { try updater.rename(entryAt: index, to: name) }
                    if operation == 12 { try updater.add(data: Data([33]), as: "added", modificationDate: TestSupport.date) }
                    let writes = IOEvents(), reads = IOEvents()
                    var progress: [ArchiveUpdater.CommitProgress] = []
                    try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                        try SegmentedArchiveOutput.$verificationReadObserver.withValue(reads.write) { try updater.commit { progress.append($0) } }
                    }
                    let added = [5, 6, 12].contains(operation)
                    let new = try LHAUpdateSupport.scan(output)
                    let expected = old.2.entries.filter { !removed.contains($0.index) }.map { renamed[$0.index] ?? $0.name } + (added ? ["added"] : [])
                    XCTAssertEqual(new.2.entries.map(\.name), expected)
                    XCTAssertEqual(updater.entryNames, old.2.entries.map(\.name))
                    try LHAUpdateSupport.unchanged(old, new, indices: (0..<6).filter { !removed.contains($0) && renamed[$0] == nil })
                    for (index, name) in renamed {
                        let newIndex = try XCTUnwrap(new.2.entries.firstIndex { $0.name == name })
                        XCTAssertEqual(try LHAUpdateSupport.digest(old.2, index), try LHAUpdateSupport.digest(new.2, newIndex))
                    }
                    let appendedLength = added ? try new.0.member(new.0.count - 1).headerRange.lowerBound.distance(to: new.0.membersEnd) : 0
                    XCTAssertEqual(progress.first?.completedBytes, 0)
                    XCTAssertEqual(progress.last?.totalBytes, writes.bytes + reads.bytes + UInt64(appendedLength))
                    XCTAssertEqual(progress.last?.completedBytes, progress.last?.totalBytes)
                    XCTAssertEqual(Set(progress.map(\.totalBytes)).count, 1)
                    XCTAssertEqual(progress.map(\.completedBytes), progress.map(\.completedBytes).sorted())
                    let bytes = try Data(contentsOf: output)
                    if operation == 0 || operation == 8 {
                        XCTAssertEqual(bytes, before); XCTAssertEqual(updater.lastCommitStrategy, .unchanged)
                    } else {
                        XCTAssertEqual(UInt64(bytes.count), new.0.membersEnd + 1); XCTAssertEqual(bytes.last, 0)
                        let strategy: LHAUpdater.CommitStrategy = operation == 5 || (operation == 6 && sequential) ? .relocatedAppend
                            : sequential ? .sequential : [1, 2, 7].contains(operation) ? .inPlacePatch : operation == 12 ? .appendOnly : .splice
                        XCTAssertEqual(updater.lastCommitStrategy, strategy, "operation \(operation), sequential \(sequential)")
                    }
                    if operation == 7 { XCTAssertEqual(bytes, Data([0])) }
                    XCTAssertEqual(try Data(contentsOf: source), before)
                    XCTAssertEqual(try ZipEditTestSupport.info(source).st_ino, info.st_ino)
                    XCTAssertEqual(try ZipEditTestSupport.info(source).st_mtimespec.tv_sec, info.st_mtimespec.tv_sec)
                    XCTAssertEqual(try ZipEditTestSupport.info(output).st_mode & 0o777, 0o600)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["out.lzh"])
                    try updater.commit()
                }
            }
        }
    }
    func testFrozenFixtureDeletesAppendAndFirstHeaderDetection() throws {
        let root = try TestSupport.directory("lha-frozen-operations")
        for name in LHAUpdateSupport.accepted {
            let source = try LHAUpdateSupport.fixture(name, in: root), old = try LHAUpdateSupport.scan(source)
            for index in Set([0, old.0.count / 2, old.0.count - 1]) where index >= 0 {
                let output = root.appendingPathComponent("out-\(name)-\(index).lzh")
                let editor = try LHAUpdater.open(url: source, output: output)
                try editor.remove(entriesAt: [index])
                try editor.add(data: Data([3]), as: "new-member", modificationDate: TestSupport.date)
                try editor.commit()
                let reader = try ArchiveReader.open(url: output), bytes = try ArchiveFileSource(url: output)
                for previous in old.2.entries where previous.index != index {
                    let entry = try XCTUnwrap(reader.entries.first { $0.name == previous.name })
                    let start = try XCTUnwrap(UInt64(entry.formatSpecific["headerOffset"] ?? ""))
                    let end = try XCTUnwrap(UInt64(entry.formatSpecific["dataOffset"] ?? "")) + (entry.compressedSize ?? 0)
                    let member = try old.0.member(previous.index)
                    XCTAssertEqual(try LHAUpdateSupport.bytes(old.1, member.headerRange.lowerBound..<member.dataRange.upperBound), try LHAUpdateSupport.bytes(bytes, start..<end), name)
                    XCTAssertEqual(try old.2.read(previous), try reader.read(entry), name)
                }
                XCTAssertEqual(reader.entries.last?.name, "new-member")
                XCTAssertEqual(try reader.read(reader.entries.last!), Data([3]))
                XCTAssertEqual(try FormatDetector.detect(url: output), .lha)
            }
        }
    }
    func testEmptyRootDirectoriesSizesAndReservationOrders() throws {
        let root = try TestSupport.directory("lha-add-sizes")
        for sequential in [false, true] {
            try LHAUpdater.$testingDisablesClone.withValue(sequential) {
                let source = root.appendingPathComponent("source-\(sequential).lzh")
                try (LHAHeaderBuilder.member(level: 0, name: ".", directory: true) + Data([0])).write(to: source)
                let output = root.appendingPathComponent("out-\(sequential).lzh")
                let editor = try LHAUpdater.open(url: source, output: output)
                for size in [0, 1, 1 << 20, 3 << 20] {
                    try editor.add(data: Data(repeating: 65, count: size), as: "file-\(size)", modificationDate: TestSupport.date)
                }
                try editor.addDirectory("dir", modificationDate: TestSupport.date, ownerIDs: nil)
                try editor.rename(entryAt: 0, to: "root-renamed")
                try editor.commit()
                let reader = try ArchiveReader.open(url: output)
                XCTAssertEqual(reader.entries.map(\.name), ["root-renamed/", "file-0", "file-1", "file-1048576", "file-3145728", "dir/"])
                for entry in reader.entries where entry.kind == .file { XCTAssertEqual(UInt64(try reader.read(entry).count), entry.uncompressedSize) }
                let empty = root.appendingPathComponent("empty-\(sequential).lzh")
                try Data([0]).write(to: empty)
                let fresh = try LHAUpdater.open(url: empty, output: root.appendingPathComponent("fresh-\(sequential).lzh"))
                try fresh.addDirectory("one"); try fresh.commit()
            }
        }
        for order in 0..<3 {
            let work = try TestSupport.work(in: root), source = try LHAUpdateSupport.generated(work)
            let editor = try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))
            if order != 0 { try editor.add(data: Data(), as: "early") }
            try editor.remove(entriesAt: [1])
            try editor.add(data: Data(), as: "file-000001")
            if order != 1 { try editor.rename(entryAt: 2, to: "renamed") }
            try editor.commit()
        }
    }
    func testCloneIO500Members() throws {
        let root = try TestSupport.directory("lha-io")
        let source = try LHAUpdateSupport.generated(root, count: 500, size: 65536)
        let (layout, _, _) = try LHAUpdateSupport.scan(source)
        for operation in 0..<4 {
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
            let editor = try LHAUpdater.open(url: source, output: output)
            let snapshot = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first)
            let inode = UInt64(try ZipEditTestSupport.info(snapshot).st_ino)
            if operation == 0 { try editor.remove(entriesAt: [499]) }
            if operation == 1 { try editor.rename(entryAt: 250, to: "edit-000250") }
            if operation == 2 { try editor.add(data: Data(count: 1024), as: "new") }
            if operation == 3 { try editor.remove(entriesAt: [250]) }
            let writes = IOEvents(), copies = IOEvents(), verification = IOEvents()
            try ZipCopyEngine.$writeObserver.withValue(writes.write) {
                try ArchiveFileSource.$readObserver.withValue(copies.read) {
                    try SegmentedArchiveOutput.$verificationReadObserver.withValue(verification.write) { try editor.commit() }
                }
            }
            let copied = copies.events.filter { $0.inode == inode }.reduce(UInt64(0)) { $0 + UInt64($1.count) }
            let header = UInt64(try layout.member(250).headerRange.count)
            if operation < 3 { XCTAssertEqual(copied, 0) }
            if operation == 0 { XCTAssertEqual(writes.bytes, 1) }
            if operation == 1 { XCTAssertEqual(writes.bytes, header + 1) }
            if operation == 2 { XCTAssertEqual(writes.bytes, 1); XCTAssertEqual(verification.bytes, 0) }
            if operation == 3 {
                let moved = try layout.membersEnd - layout.member(251).headerRange.lowerBound
                XCTAssertEqual(copied, moved); XCTAssertEqual(writes.bytes, moved + 1)
                XCTAssertLessThanOrEqual(verification.bytes, 2 * moved + 4 * header)
            }
        }
    }
    func testRootCarryDirectoryLevelsNoopAndDiskAdd() throws {
        let root = try TestSupport.directory("lha-root-and-directories"), source = root.appendingPathComponent("source.lzh")
        var bytes = LHAHeaderBuilder.member(level: 0, name: ".", directory: true)
        for level: UInt8 in 0...2 { bytes += LHAHeaderBuilder.member(level: level, name: "dir-\(level)/", directory: true) }
        try (bytes + Data([0])).write(to: source)
        let before = try LHAUpdateSupport.scan(source), output = root.appendingPathComponent("out.lzh")
        let editor = try LHAUpdater.open(url: source, output: output)
        try editor.rename(entryAt: 1, to: "temporary")
        try editor.rename(entryAt: 1, to: "dir-0/")
        try editor.rename(entryAt: 2, to: "日本")
        try editor.rename(entryAt: 3, to: "short")
        let disk = root.appendingPathComponent("disk"), data = Data([1, 2, 3])
        try data.write(to: disk)
        XCTAssertThrowsError(try editor.add(contentsOf: disk, as: "disk", ownerIDs: .init(user: 501, group: 20))) {
            XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs"))
        }
        try editor.add(contentsOf: disk, as: "disk", ownerIDs: nil)
        try editor.commit()
        let after = try LHAUpdateSupport.scan(output)
        try LHAUpdateSupport.unchanged(before, after, indices: [0, 1])
        XCTAssertEqual(after.2.entries.map(\.name), [".", "dir-0/", "日本/", "short/", "disk"])
        XCTAssertEqual(try after.2.read(after.2.entries[4]), data)
        for index in [2, 3] { XCTAssertEqual(try after.0.member(index).headerLevel, 2) }
    }
}
