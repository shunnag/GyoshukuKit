import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class UpdaterRouteErrorTests: XCTestCase {
    func testAliasEqualityAndBothCatchPatterns() {
        let old = TarUpdaterError.requiresRewrite(reason: "reason")
        XCTAssertEqual(old, UpdaterRouteError.requiresRewrite(reason: "reason"))
        do { throw old } catch UpdaterRouteError.requiresRewrite(let reason) { XCTAssertEqual(reason, "reason") } catch { XCTFail("\(error)") }
        do { throw UpdaterRouteError.outputVerificationFailed(reason: "V5") }
        catch TarUpdaterError.outputVerificationFailed(let reason) { XCTAssertEqual(reason, "V5") } catch { XCTFail("\(error)") }
    }
}

final class LHALayoutTests: XCTestCase {
    func testIndependentWalkMatchesFrozenFixtures() throws {
        let root = try ZipTestSupport.directory("lha-layout")
        for name in LHAUpdateSupport.accepted {
            let url = try LHAUpdateSupport.fixture(name, in: root)
            let (layout, _, reader) = try LHAUpdateSupport.scan(url)
            XCTAssertEqual(layout.count, reader.entries.count, name)
            XCTAssertNil(LHAUpdater.rewriteReason(reader: reader), name)
        }
    }
    func testBuilderLevelsNamesCRCsAndPayloadSkipping() throws {
        let root = try ZipTestSupport.directory("lha-builder")
        let url = root.appendingPathComponent("source.lzh")
        var bytes = Data()
        for level: UInt8 in 0...2 {
            bytes += LHAHeaderBuilder.member(level: level, name: "level-\(level)", data: Data(repeating: level, count: 16384))
            bytes += LHAHeaderBuilder.member(level: level, name: "dir-\(level)/", directory: true)
        }
        try (bytes + Data([0])).write(to: url)
        let source = try ZipUpdateSource(url: url), reads = ZipIOEvents()
        let result = try ZipUpdateSource.$readObserver.withValue(reads.read) {
            try LHALayout.walk(source: source, range: 0..<source.length) { _, _ in }
        }
        XCTAssertEqual(result.count, 6)
        XCTAssertLessThan(reads.bytes, 20000)
        let (layout, _, reader) = try LHAUpdateSupport.scan(url)
        XCTAssertEqual(layout.count, 6)
        for entry in reader.entries where entry.kind == .file { XCTAssertEqual(try reader.read(entry).count, 16384) }
        bytes[1] ^= 1
        try (bytes + Data([0])).write(to: url)
        let damaged = try ZipUpdateSource(url: url)
        XCTAssertThrowsError(try LHALayout.walk(source: damaged, range: 0..<damaged.length) { _, _ in })
    }
    func testLargeHeadersLevelOneCRCAndLevelThreeBuilder() throws {
        let root = try ZipTestSupport.directory("lha-large-headers")
        for level: UInt8 in [1, 2, 3] {
            let source = root.appendingPathComponent("level-\(level).lzh")
            let name = Data("name".utf8)
            let extras: [(UInt8, Data)] = level == 1 ? [(UInt8(0), Data(count: 2)), (UInt8(1), Data(repeating: 97, count: 5000))] : [(UInt8(0x3f), Data(repeating: 97, count: 5000))]
            let h = LHAHeaderBuilder.header(level: level, name: name, packed: 0, original: 0, crc: 0, extensions: extras)
            try (h + Data([0])).write(to: source)
            if level == 3 {
                XCTAssertThrowsError(try LHAUpdater.open(url: source, output: root.appendingPathComponent("out.lzh"))) {
                    guard case UpdaterRouteError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
                    XCTAssertTrue(reason.contains("L5"), reason)
                }
            } else {
                let (layout, _, _) = try LHAUpdateSupport.scan(source)
                XCTAssertGreaterThan(try layout.member(0).headerRange.count, 4096)
            }
        }
    }
}

final class LHAEditPlanTests: XCTestCase {
    func testMergingOffsetsBoundariesAndFreshTerminator() throws {
        let root = try ZipTestSupport.directory("lha-plan")
        let url = try LHAUpdateSupport.generated(root)
        let (layout, _, _) = try LHAUpdateSupport.scan(url)
        let unchanged = try LHAEditPlan.make(layout: layout, removed: [], renamed: [:])
        XCTAssertEqual(unchanged.prefix.count, 1)
        XCTAssertTrue(unchanged.terminal.isEmpty)
        XCTAssertTrue(unchanged.boundaries.isEmpty)
        let removed = try LHAEditPlan.make(layout: layout, removed: [1, 3], renamed: [:])
        XCTAssertEqual(removed.prefix.count, 3)
        XCTAssertEqual(removed.boundaries.count, 3)
        XCTAssertNil(removed.memberOffsets[1])
        XCTAssertNil(removed.memberOffsets[3])
        XCTAssertEqual(removed.terminal, Data([0]))
        let all = try LHAEditPlan.make(layout: layout, removed: Set(0..<6), renamed: [:])
        XCTAssertTrue(all.prefix.isEmpty)
        XCTAssertEqual(all.membersEnd, 0)
        let header = try LHARecords.Entry(name: "renamed", mode: 0o100644, size: 513, date: ZipTestSupport.date).header(method: "-lh5-", packedSize: 513, crc: 0)
        let renamed = try LHAEditPlan.make(layout: layout, removed: [], renamed: [2: header], additionLength: 1)
        XCTAssertEqual(renamed.prefix.count, 3)
        XCTAssertEqual(renamed.changed.count, 1)
        XCTAssertEqual(renamed.boundaries.count, 1)
    }
}

final class LHAHeaderReemitTests: XCTestCase {
    func testEveryAcceptedFixturePreservesPayloadAndReemitsExactHeader() throws {
        let root = try ZipTestSupport.directory("lha-header-reemit")
        for name in LHAUpdateSupport.accepted {
            let url = try LHAUpdateSupport.fixture(name, in: root)
            let old = try LHAUpdateSupport.scan(url)
            let output = root.appendingPathComponent("out-\(name).lzh")
            let updater = try LHAUpdater.open(url: url, output: output)
            for entry in old.2.entries {
                try updater.rename(entryAt: entry.index, to: "日本/renamed-\(entry.index)" + (entry.kind == .directory ? "/" : ""))
            }
            try updater.commit()
            let new = try LHAUpdateSupport.scan(output)
            for entry in old.2.entries {
                let a = try old.0.member(entry.index), b = try new.0.member(entry.index)
                let expected = try LHARecords.Entry(name: new.2.entries[entry.index].name, mode: ArchiveRewriter.mode(for: entry), size: entry.uncompressedSize ?? 0, date: entry.modificationDate ?? ZipTestSupport.date)
                    .header(method: a.method, packedSize: UInt32(a.dataRange.count), crc: a.method == "-lhd-" ? 0 : a.crc16)
                XCTAssertEqual(try LHAUpdateSupport.bytes(new.1, b.headerRange), expected, name)
                XCTAssertEqual(try LHAUpdateSupport.bytes(old.1, a.dataRange), try LHAUpdateSupport.bytes(new.1, b.dataRange), name)
                XCTAssertEqual(try LHAUpdateSupport.digest(old.2, entry.index), try LHAUpdateSupport.digest(new.2, entry.index), name)
                XCTAssertEqual(b.headerLevel, 2); XCTAssertEqual(b.osID, 0x55)
            }
        }
    }
}
