import Foundation
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipMixedCommitTests: XCTestCase {
    func testFourOrdersShrinkGrowAndWrittenOverlapMatchLegacy() throws {
        let directory = try ZipTestSupport.directory("p1-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory, payloadSize: 512)
        let payload = Data(repeating: 77, count: 6000)
        let cases: [([ZipP1Support.Operation], ArchiveUpdater.CommitStrategy)] = [
            ([.remove([0]), .add("added", payload)], .rebuildThenAppend),
            ([.add("added", payload), .remove([0])], .stagedRebuild),
            ([.remove([0]), .add("added", payload), .rename(1, "longer-name.txt")], .stagedRebuild),
            ([.add("added", payload), .remove([0]), .add("second", payload)], .stagedRebuild),
            ([.rename(0, "x"), .add("added", payload)], .rebuildThenAppend),
            ([.rename(0, "much-longer-name.txt"), .add("added", payload)], .rebuildThenAppend)
        ]
        for (index, item) in cases.enumerated() {
            try ZipP1Support.compare(source, operations: item.0, label: "order-\(index)", expectedStrategy: item.1)
        }
        // 削除で空いた長さを改名で戻し、後続 record の start == lb と W の交差を同時に作る。
        let updater = try ArchiveUpdater.open(url: source)
        let first = try XCTUnwrap(updater.validatedLayout(at: 0))
        let length = Int(first.recordRange.upperBound - first.recordRange.lowerBound)
        let longName = String(repeating: "n", count: "middle.txt".utf8.count + length)
        try ZipP1Support.compare(source, operations: [.remove([0]), .add("added", payload), .rename(1, longName)],
                                label: "written-overlap", expectedStrategy: .stagedRebuild)
    }

    func testAppOrderDoesNotRereadOriginalCentralOrUnmovedPayload() throws {
        let directory = try ZipTestSupport.directory("p1-mixed-read-bound")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory, count: 20, payloadSize: 256 * 1024)
        let updater = try ArchiveUpdater.open(url: source)
        try updater.remove(entriesAt: [19])
        try updater.add(data: Data([1]), as: "added", modificationDate: ZipTestSupport.date)
        var calls: [Int] = []
        updater.recordLayout = { index in calls.append(index); return updater.validatedLayout(at: index) }
        let events = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(events.read) { try updater.commit() }
        XCTAssertEqual(updater.lastCommitStrategy, .rebuildThenAppend)
        XCTAssertEqual(calls, Array(0..<19))
        XCTAssertEqual(events.bytes, 0)
    }

    func testMixedReadBoundAndNoGapReadWithSmallBuffer() throws {
        let directory = try ZipTestSupport.directory("p1-mixed-exact-reads")
        defer { try? FileManager.default.removeItem(at: directory) }
        for staged in [false, true] {
            let source = try ZipP1Support.fixture(directory, name: "large-\(staged).zip", count: 3, payloadSize: 8 * 1024 * 1024)
            let inode = try ZipP1Support.info(source).st_ino
            let updater = try ArchiveUpdater.open(url: source, options: .init(compressionMethod: .stored))
            let survivors = try [1, 2].map { try XCTUnwrap(updater.validatedLayout(at: $0)).recordRange }
            let moved = survivors.reduce(UInt64(0)) { $0 + $1.upperBound - $1.lowerBound }
            try updater.remove(entriesAt: [0])
            if !staged { try updater.rename(entryAt: 1, to: "a-much-longer-file-name.txt") }
            try updater.add(data: Data(repeating: 1, count: 2 * 1024 * 1024), as: "added", modificationDate: ZipTestSupport.date)
            if staged { try updater.rename(entryAt: 1, to: "x") }
            let events = ZipIOEvents()
            try ZipUpdateSource.$readObserver.withValue(events.read) { try updater.commit() }
            let originalReads = events.events.filter { $0.inode == inode }.reduce(UInt64(0)) { $0 + UInt64($1.count) }
            XCTAssertGreaterThanOrEqual(originalReads, moved - 128)
            XCTAssertLessThan(originalReads, moved + 1024 * 1024)
            XCTAssertEqual(updater.lastCommitStrategy, staged ? .stagedRebuild : .rebuildThenAppend)
        }
        let source = try ZipP1Corpus.crafted(directory, variant: "gap")
        let output = directory.appendingPathComponent("gap-output.zip"), oracle = directory.appendingPathComponent("gap-oracle.zip")
        try ZipP1Support.legacy(source: source, output: oracle, operations: [.remove([4])])
        let updater = try ArchiveUpdater.open(url: source, output: output)
        let gap = try XCTUnwrap(updater.validatedLayout(at: 0)).recordRange.upperBound..<XCTUnwrap(updater.validatedLayout(at: 1)).recordRange.lowerBound
        try updater.remove(entriesAt: [4])
        let events = ZipIOEvents()
        try ZipCopyEngine.$testingBufferSize.withValue(17) {
            try ZipUpdateSource.$readObserver.withValue(events.read) { try updater.commit() }
        }
        XCTAssertFalse(events.events.contains { ($0.offset..<($0.offset + UInt64($0.count))).overlaps(gap) })
        try ZipP1Support.assertEqualFiles(output, oracle)
    }

    func testCorruptionFailsBothGKAndIndependentKaitoCheck() throws {
        let directory = try ZipTestSupport.directory("p1-mixed-corruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        for bypass in [false, true] {
            let source = try ZipP1Support.fixture(directory, name: "source-\(bypass).zip")
            let before = try Data(contentsOf: source), identity = try ZipP1Support.info(source)
            let output = directory.appendingPathComponent("output-\(bypass).zip")
            let updater = try ArchiveUpdater.open(url: source, output: output)
            try updater.remove(entriesAt: [0])
            try updater.add(data: Data([1]), as: "added", modificationDate: ZipTestSupport.date)
            try ZipAppendedRecordCheck.$testingSkipHeaderEquality.withValue(bypass) {
                try ArchiveUpdater.$testingAppendedCorruption.withValue({ $0[0] ^= 1 }) {
                    XCTAssertThrowsError(try updater.commit()) {
                        guard case UpdaterError.invalidArchive(let reason) = $0 else { return XCTFail("\($0)") }
                        XCTAssertTrue(reason.contains("追加した record を KaitoKit で照合できません"))
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try ZipP1Support.info(source).st_ino, identity.st_ino)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testDeleteDefersReservationsAndLaterMutationsKeepCollisionRules() throws {
        let directory = try ZipTestSupport.directory("p1-lazy-paths")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Support.fixture(directory)
        for order in 0..<3 {
            let updater = try ArchiveUpdater.open(url: source)
            XCTAssertFalse(updater.hasPathReservations)
            if order == 1 { try updater.add(data: Data(), as: "added") }
            if order == 2 { try updater.rename(entryAt: 1, to: "temporary") }
            try updater.remove(entriesAt: [0])
            XCTAssertEqual(updater.hasPathReservations, order == 2)
            try updater.rename(entryAt: 1, to: "first.txt")
            XCTAssertTrue(updater.hasPathReservations)
            XCTAssertThrowsError(try updater.rename(entryAt: 2, to: "first.txt"))
        }
        let updater = try ArchiveUpdater.open(url: source)
        try updater.remove(entriesAt: [0])
        XCTAssertThrowsError(try updater.rename(entryAt: 1, to: "folder"))
    }
}
