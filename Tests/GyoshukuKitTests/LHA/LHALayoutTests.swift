import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHALayoutTests: XCTestCase {
    func testIndependentWalkMatchesFrozenFixtures() throws {
        let root = try TestSupport.directory("lha-layout")
        for name in LHAUpdateSupport.accepted {
            let url = try LHAUpdateSupport.fixture(name, in: root)
            let (layout, _, reader) = try LHAUpdateSupport.scan(url)
            XCTAssertEqual(layout.count, reader.entries.count, name)
            XCTAssertNil(LHAUpdater.rewriteReason(reader: reader), name)
        }
    }
    func testBuilderLevelsNamesCRCsAndPayloadSkipping() throws {
        let root = try TestSupport.directory("lha-builder")
        let url = root.appendingPathComponent("source.lzh")
        var bytes = Data()
        for level: UInt8 in 0...2 {
            bytes += LHAHeaderBuilder.member(level: level, name: "level-\(level)", data: Data(repeating: level, count: 16384))
            bytes += LHAHeaderBuilder.member(level: level, name: "dir-\(level)/", directory: true)
        }
        try (bytes + Data([0])).write(to: url)
        let source = try ArchiveFileSource(url: url), reads = IOEvents()
        let result = try ArchiveFileSource.$readObserver.withValue(reads.read) {
            try LHALayout.walk(source: source, range: 0..<source.length) { _, _ in }
        }
        XCTAssertEqual(result.count, 6)
        XCTAssertLessThan(reads.bytes, 20000)
        let (layout, _, reader) = try LHAUpdateSupport.scan(url)
        XCTAssertEqual(layout.count, 6)
        for entry in reader.entries where entry.kind == .file { XCTAssertEqual(try reader.read(entry).count, 16384) }
        bytes[1] ^= 1
        try (bytes + Data([0])).write(to: url)
        let damaged = try ArchiveFileSource(url: url)
        XCTAssertThrowsError(try LHALayout.walk(source: damaged, range: 0..<damaged.length) { _, _ in })
    }
    func testLargeHeadersLevelOneCRCAndLevelThreeBuilder() throws {
        let root = try TestSupport.directory("lha-large-headers")
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
