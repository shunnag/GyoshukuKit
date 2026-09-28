import Foundation
import XCTest
@testable import GyoshukuKit

final class LiveNameCheckTests: XCTestCase {
    private enum Outcome: Equatable {
        case accepted, duplicate([UInt8]), invalid([UInt8])
    }

    private func outcome(_ body: () throws -> Void) throws -> Outcome {
        do { try body(); return .accepted }
        catch WriterError.duplicatePath(let name) { return .duplicate(Array(name.utf8)) }
        catch WriterError.invalidPath(let name) { return .invalid(Array(name.utf8)) }
    }

    private struct Random {
        var state: UInt64 = 0x31_5041_5448
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
    }

    private var adversarialNames: [String] {
        ["a", "a/b", "a//b", "a//b/c", "/a", "/a/b", "a/", "a//", "", "/", "//",
         "café", "cafe\u{301}", "café/child", "cafe\u{301}/child", "K", "\u{212A}",
         "K/child", "\u{212A}/child", ";", "\u{037E}", ";/child", "\u{037E}/child",
         "日本語", "日本語/子", "a/\u{301}b", "a/\u{301}b/child", "a/b/", "a/b//",
         "a/b/c/d/e/f", "a/b/c/d/e/f/g", "a", "a/b", "./a", "a/../b",
         Array(repeating: "deep", count: 64).joined(separator: "/") + "/leaf"]
    }

    private func oracle(_ mode: LiveNameCheck.Mode, paths: [(String, Bool)], name: String,
                        directory: Bool, root: URL) throws -> Outcome {
        if mode == .reservations {
            return try outcome { try EditPathReservations(paths).validate(name, directory: directory) }
        }
        let url = root.appendingPathComponent("oracle.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored, compressionThreads: 1))
        try writer.prepareAppend(at: 0, existingPaths: paths)
        return try outcome {
            if directory { try writer.addDirectory(name) }
            else { try writer.add(data: Data([1]), as: name, modificationDate: TestSupport.date) }
        }
    }

    private func checkOracle(_ mode: LiveNameCheck.Mode) throws {
        let root = try TestSupport.directory("live-name-oracle-\(mode)")
        defer { try? FileManager.default.removeItem(at: root) }
        var random = Random()
        let names = adversarialNames
        let candidates = names.compactMap { name in
            try? ArchiveWriter.normalizedPath(name.hasSuffix("/") ? String(name.dropLast()) : name,
                                             directory: false, format: .zip)
        }
        var totals: [Outcome] = []
        for trace in 0..<100 {
            var original = names.enumerated().flatMap { [($0.element, $0.offset.isMultiple(of: 2)), ($0.element, !$0.offset.isMultiple(of: 2))] }
            while original.count < 120 + trace % 31 {
                original.append(("group\(random.next(8))/file\(random.next(30))", random.next(3) == 0))
            }
            let snapshot = LiveNameCheck(count: original.count) { original[$0] }
            var excluded = [Bool](repeating: false, count: original.count)
            var removed: Set<Int> = []
            var renamed: [Int: String] = [:]
            var appended: [(String, Bool)] = []
            for step in 0..<100 {
                let index = random.next(original.count)
                let fresh = candidates[random.next(candidates.count)]
                switch random.next(3) {
                case 0:
                    removed.insert(index)
                    renamed.removeValue(forKey: index)
                    excluded[index] = true
                case 1 where !removed.contains(index):
                    renamed[index] = try ArchiveWriter.normalizedPath(fresh, directory: original[index].1, format: .zip)
                    excluded[index] = true
                default:
                    let directory = random.next(2) == 0
                    appended.append((try ArchiveWriter.normalizedPath(fresh, directory: directory, format: .zip), directory))
                }
                let directory = random.next(2) == 0
                let path = step.isMultiple(of: 5) ? "unused-\(trace)-\(step)/child" : candidates[random.next(candidates.count)]
                let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .zip)
                let excluding = mode == .reservations && !removed.contains(index) && random.next(2) == 0 ? index : nil
                let live = original.indices.filter { !removed.contains($0) && $0 != excluding }
                    .map { (renamed[$0] ?? original[$0].0, original[$0].1) } + appended
                XCTAssertTrue((50...200).contains(live.count))
                let expected = try oracle(mode, paths: live, name: name, directory: directory, root: root)
                let actual = try outcome {
                    try snapshot.validate(name, directory: directory, mode: mode, excluded: excluded,
                                          excluding: excluding, renamed: renamed, appended: appended)
                }
                XCTAssertEqual(actual, expected, "\(mode) trace=\(trace) step=\(step) name=\(name)")
                totals.append(actual)
            }
        }
        XCTAssertEqual(totals.count, 10_000)
        XCTAssertTrue(totals.contains(.accepted))
        XCTAssertTrue(totals.contains { if case .duplicate = $0 { return true }; return false })
        XCTAssertTrue(totals.contains { if case .invalid = $0 { return true }; return false })
    }

    func testReservationsAgreeWithRealTableForTenThousandCandidates() throws { try checkOracle(.reservations) }
    func testWriterAgreesWithRealWriterForTenThousandCandidates() throws { try checkOracle(.writer) }

    func testEmptyComponentsCanonicalEquivalenceAndErrorPriority() throws {
        let root = try TestSupport.directory("live-name-fixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [([(String, Bool)], String, Bool, Outcome, Outcome)] = [
            ([("a//b/c", false)], "a/b", false, .accepted, .invalid(Array("a/b".utf8))),
            ([("/a/b", false)], "a", false, .accepted, .invalid(Array("a".utf8))),
            ([("a", false), ("a/b", true)], "a/b/", true, .invalid(Array("a/b/".utf8)), .duplicate(Array("a/b/".utf8))),
            ([("\u{212A}", false)], "K", false, .duplicate([75]), .duplicate([75])),
            ([("\u{037E}", false)], ";/child", false, .invalid(Array(";/child".utf8)), .invalid(Array(";/child".utf8))),
            ([("cafe\u{301}/child", false)], "café", false, .invalid(Array("café".utf8)), .invalid(Array("café".utf8))),
            ([("a/\u{301}b", false)], "a", false, .invalid([97]), .invalid([97])),
            ([("a//b", false)], "a/b/child", false, .accepted, .accepted),
            ([("K", false)], "\u{212A}", false, .duplicate([75]), .duplicate([75]))
        ]
        for (paths, path, directory, reservations, writer) in cases {
            let snapshot = LiveNameCheck(count: paths.count) { paths[$0] }
            let name = try ArchiveWriter.normalizedPath(path, directory: directory, format: .zip)
            for (mode, expected) in [(LiveNameCheck.Mode.reservations, reservations), (.writer, writer)] {
                XCTAssertEqual(try oracle(mode, paths: paths, name: name, directory: directory, root: root), expected)
                XCTAssertEqual(try outcome {
                    try snapshot.validate(name, directory: directory, mode: mode,
                        excluded: [Bool](repeating: false, count: paths.count), renamed: [:], appended: [])
                }, expected)
            }
        }
        let duplicates = [("café", false), ("cafe\u{301}", true)]
        let snapshot = LiveNameCheck(count: 2) { duplicates[$0] }
        XCTAssertEqual(try outcome {
            try snapshot.validate("café", directory: false, mode: .reservations,
                                  excluded: [true, false], excluding: 0, renamed: [:], appended: [])
        }, .duplicate(Array("café".utf8)))
    }

    private func fixture(_ root: URL, count: Int = 8) throws -> URL {
        let source = root.appendingPathComponent("source.zip")
        let writer = try ArchiveWriter.create(url: source, options: .init(compressionMethod: .stored))
        for index in 0..<count {
            try writer.add(data: Data([UInt8(index % 256)]), as: "file\(index)", modificationDate: TestSupport.date)
        }
        try writer.finish()
        return source
    }

    private func compareUpdates(_ label: String, _ edits: (ArchiveUpdater, Int) throws -> Void) throws {
        let root = try TestSupport.directory("live-name-\(label)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root)
        var outputs: [Data] = []
        for budget in [0, 4, Int.max] {
            let output = root.appendingPathComponent("output-\(budget).zip")
            try ArchiveUpdater.$testingNameCheckMinimumEntries.withValue(0) {
                try ArchiveUpdater.$testingNameCheckBudget.withValue(budget) {
                    let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(compressionMethod: .stored))
                    try edits(updater, budget)
                    try updater.commit()
                }
            }
            outputs.append(try Data(contentsOf: output))
        }
        XCTAssertEqual(outputs[0], outputs[1])
        XCTAssertEqual(outputs[0], outputs[2])
    }

    func testFourAdditionsScanAndFifthBuildsWriterTable() throws {
        try compareUpdates("addition-budget") { updater, budget in
            for index in 0..<4 {
                try updater.add(data: Data([1]), as: "added\(index)", modificationDate: TestSupport.date)
            }
            XCTAssertEqual(updater.nameCheckScanCount, budget == 0 ? 0 : 4)
            XCTAssertEqual(updater.writerUsesLiveNameCheck, budget != 0)
            XCTAssertFalse(updater.hasPathReservations)
            try updater.add(data: Data([1]), as: "added4", modificationDate: TestSupport.date)
            XCTAssertEqual(updater.writerUsesLiveNameCheck, budget == Int.max)
            XCTAssertEqual(updater.nameCheckScanCount, budget == 0 ? 0 : budget == 4 ? 4 : 5)
        }
    }

    func testFourRenamesScanAndFifthBuildsReservations() throws {
        try compareUpdates("rename-budget") { updater, budget in
            for index in 0..<4 { try updater.rename(entryAt: index, to: "renamed\(index)") }
            XCTAssertEqual(updater.nameCheckScanCount, budget == 0 ? 0 : 4)
            XCTAssertEqual(updater.hasPathReservations, budget == 0)
            try updater.rename(entryAt: 4, to: "renamed4")
            XCTAssertEqual(updater.hasPathReservations, budget != Int.max)
            XCTAssertEqual(updater.nameCheckScanCount, budget == 0 ? 0 : budget == 4 ? 4 : 5)
        }
    }

    func testMixedReservationsReleaseNamesAndShareOneBudget() throws {
        try compareUpdates("mixed-budget") { updater, budget in
            try updater.remove(entriesAt: [7, 7])
            XCTAssertEqual(updater.nameCheckScanCount, 0)
            XCTAssertFalse(updater.hasPathReservations)
            try updater.add(data: Data([1]), as: "file7", modificationDate: TestSupport.date)
            try updater.rename(entryAt: 0, to: "temporary")
            try updater.rename(entryAt: 0, to: "changed")
            try updater.remove(entriesAt: [0])
            try updater.add(data: Data([2]), as: "file0", modificationDate: TestSupport.date)
            XCTAssertEqual(updater.nameCheckScanCount, budget == 0 ? 0 : 4)
            try updater.rename(entryAt: 1, to: "temporary")
            XCTAssertEqual(updater.hasPathReservations, budget != Int.max)
            try updater.add(data: Data([3]), as: "changed", modificationDate: TestSupport.date)
            XCTAssertEqual(updater.writerUsesLiveNameCheck, budget == Int.max)
            try updater.rename(entryAt: 2, to: "file1")
            try updater.remove(entriesAt: [1])
            try updater.add(data: Data([4]), as: "temporary", modificationDate: TestSupport.date)
        }
    }

    func testDefaultMinimumEntryBoundary() throws {
        for count in [2_047, 2_048] {
            let root = try TestSupport.directory("live-name-minimum-\(count)")
            defer { try? FileManager.default.removeItem(at: root) }
            let updater = try ArchiveUpdater.open(url: fixture(root, count: count))
            try updater.add(data: Data([1]), as: "added")
            XCTAssertEqual(updater.writerUsesLiveNameCheck, count == 2_048)
            try updater.rename(entryAt: 0, to: "renamed")
            XCTAssertEqual(updater.nameCheckScanCount, count == 2_048 ? 2 : 0)
            XCTAssertEqual(updater.hasPathReservations, count == 2_047)
        }
    }

    private enum Edit {
        case add(String), directory(String), rename(Int, String), remove([Int])
        func apply(to updater: ArchiveUpdater) throws {
            switch self {
            case .add(let name): try updater.add(data: Data([42]), as: name, modificationDate: TestSupport.date)
            case .directory(let name): try updater.addDirectory(name, modificationDate: TestSupport.date, ownerIDs: nil)
            case .rename(let index, let name): try updater.rename(entryAt: index, to: name)
            case .remove(let indices): try updater.remove(entriesAt: indices)
            }
        }
    }

    func testTenScriptsHaveIdenticalCommittedBytesAndCollisionFailures() throws {
        let scripts: [[Edit]] = [
            [.add("new")], [.rename(0, "other")], [.remove([0, 2])], [.remove([0]), .add("file0")],
            [.directory("newdir"), .add("newdir/child")], [.rename(0, "shifted"), .add("file0")],
            [.rename(0, "temporary"), .rename(0, "final"), .remove([1]), .add("file1")],
            [.add("first"), .remove([1]), .rename(2, "else/2"), .add("file1"), .directory("empty")],
            (0..<6).map { .add("new\($0)") } + (0..<6).map { .rename($0, "changed\($0)") },
            (0..<4).map { .rename($0, "stage/\($0)") } + [.add("extra"), .remove([0]), .add("stage/0"), .directory("stage")]
        ]
        for (index, script) in scripts.enumerated() {
            try compareUpdates("bytes-\(index)") { updater, _ in
                for edit in script { try edit.apply(to: updater) }
            }
            let root = try TestSupport.directory("live-name-rejection-\(index)")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try fixture(root), original = try Data(contentsOf: source)
            for budget in [0, 4, Int.max] {
                try ArchiveUpdater.$testingNameCheckMinimumEntries.withValue(0) {
                    try ArchiveUpdater.$testingNameCheckBudget.withValue(budget) {
                        let updater = try ArchiveUpdater.open(url: source)
                        for edit in script { try edit.apply(to: updater) }
                        // 失敗は updater を閉じるので、成功 script とは別の transaction で照合する。
                        let name = index.isMultiple(of: 2) ? "file6" : "file6/child"
                        let expected: Outcome = index.isMultiple(of: 2) ? .duplicate(Array(name.utf8)) : .invalid(Array(name.utf8))
                        XCTAssertEqual(try outcome { try updater.add(data: Data(), as: name) }, expected)
                        XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
                        XCTAssertEqual(try Data(contentsOf: source), original)
                    }
                }
            }
        }
    }

    func testShiftJISFirstScanWhenEnabled() throws {
        try OptInGate.flag("GYOSHUKU_LIVE_NAME_SCALE")
        let count = 500_000
        let names = (0..<count).map { String(data: Data("d\($0 / 1_000)/s\($0 % 10)/f\($0).txt".utf8), encoding: .shiftJIS)! }
        let excluded = [Bool](repeating: false, count: count)
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = LiveNameCheck(count: count) { (names[$0], false) }
        let built = DispatchTime.now().uptimeNanoseconds
        try snapshot.validate("new-file", directory: false, mode: .writer, excluded: excluded, renamed: [:], appended: [])
        let end = DispatchTime.now().uptimeNanoseconds
        ScaleProbe.report(tag: "LIVE-NAME-SCALE", columns: ["encoding=shiftJIS", "entries=\(count)",
            "snapshot_ms=\(Double(built-start)/1_000_000)", "first_scan_ms=\(Double(end-start)/1_000_000)"])
    }
}
