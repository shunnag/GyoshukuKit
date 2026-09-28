import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class EditPathReservationsTests: XCTestCase {
    func testDeepPathsReleaseTheirBranchesWithoutRecursiveDestruction() {
        let parent = Array(repeating: "x", count: 16_000).joined(separator: "/")
        let index = EditPathReservations([])
        index.insert(parent + "/first", directory: false)
        index.insert(parent + "/second", directory: false)
        XCTAssertThrowsError(try index.validate(parent, directory: false))
        XCTAssertNoThrow(try index.validate(parent + "/", directory: true))
        index.remove(parent + "/first", directory: false)
        XCTAssertThrowsError(try index.validate("x", directory: false))
        index.remove(parent + "/second", directory: false)
        XCTAssertNoThrow(try index.validate("x", directory: false))
        index.insert("new/file", directory: false)
        XCTAssertThrowsError(try index.validate("new", directory: false))
        XCTAssertNoThrow(try index.validate("x", directory: false))
    }

    func testCountedReservationsAgreeWithPairwiseScanIncludingDuplicateNames() throws {
        let paths = ["a", "ab", "a/child", "a//child", "a/", "./a", "/", "/a",
                     "café/file", "cafe\u{301}/file", "café", "a/\u{301}b", "a/\u{301}b/child"]
        var records: [(String, Bool)] = [], index = EditPathReservations([])
        var state: UInt64 = 0x9BFC
        func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
        func descendant(_ path: String, of parent: String) -> Bool {
            path.precomposedStringWithCanonicalMapping.utf8
                .starts(with: (parent + "/").precomposedStringWithCanonicalMapping.utf8)
        }
        func key(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
        for step in 0..<400 {
            if !records.isEmpty, next(3) == 0 {
                let removed = records.remove(at: next(records.count))
                index.remove(removed.0, directory: removed.1)
            } else {
                let record = (paths[next(paths.count)], next(2) == 0)
                records.append(record)
                index.insert(record.0, directory: record.1)
            }
            for path in paths {
                for directory in [false, true] {
                    let collision = records.contains { other, otherDirectory in
                        key(other) == key(path) || (!directory && descendant(key(other), of: key(path))) ||
                            (!otherDirectory && descendant(key(path), of: key(other)))
                    }
                    do {
                        try index.validate(path, directory: directory)
                        XCTAssertFalse(collision, "step \(step), \(path)")
                    } catch {
                        XCTAssertTrue(collision, "step \(step), \(path): \(error)")
                    }
                }
            }
        }
        for (path, directory) in records { index.remove(path, directory: directory) }
        for path in paths { XCTAssertNoThrow(try index.validate(path, directory: false)) }
    }

    func testBulkRenamesAfterAddingPreserveEveryPayloadAndReleaseOldPaths() throws {
        let root = try TestSupport.directory("editing-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            for count in [1_000, 2_000, 4_000] {
                let archive = root.appendingPathComponent("\(format)-\(count)")
                let (editor, _) = try Self.bulkRename(archive, format: format, count: count)
                try editor.commit()
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.count, count + 2)
                let contents = try Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.name, try reader.read($0)) })
                XCTAssertEqual(contents["added"], Data("added".utf8))
                XCTAssertEqual(contents["source/file0"], Data("replacement".utf8))
                for index in 0..<count {
                    XCTAssertEqual(contents["renamed/file\(index)"], Data("payload-\(index)".utf8))
                }
            }
        }
    }

    /// `source/file<i>` を `count` 個持つ `format` の書庫を `archive` に作り、`added` を加えてから全 entry を `renamed/` の下へ改名する。
    /// 改名の途中で空いた旧名 `source/file0` に別の本文を足す。commit は呼び出し側が行い、改名の区間の経過時間を返す
    /// （`Probes/EditPathReservationScaleProbeTests` がその時間を測る）。
    static func bulkRename(_ archive: URL, format: GyoshukuKit.ArchiveFormat, count: Int) throws -> (editor: any ArchiveEditing, renaming: Duration) {
        let writer = try ArchiveWriter.create(url: archive, format: format, options: .init(compressionMethod: .stored))
        for index in 0..<count {
            try writer.add(data: Data("payload-\(index)".utf8), as: "source/file\(index)")
        }
        try writer.finish()
        let editor: any ArchiveEditing = format == .zip
            ? try ArchiveUpdater.open(url: archive)
            : try ArchiveRewriter.open(url: archive, format: format)
        try editor.add(data: Data("added".utf8), as: "added", modificationDate: nil, permissions: nil)
        let start = ContinuousClock.now
        for index in 0..<count {
            try editor.rename(entryAt: index, to: "renamed/file\(index)")
            if index == count / 2 {
                try editor.add(data: Data("replacement".utf8), as: "source/file0",
                               modificationDate: nil, permissions: nil)
            }
        }
        return (editor, start.duration(to: .now))
    }
}
