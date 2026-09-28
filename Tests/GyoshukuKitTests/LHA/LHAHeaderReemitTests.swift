import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAHeaderReemitTests: XCTestCase {
    func testEveryAcceptedFixturePreservesPayloadAndReemitsExactHeader() throws {
        let root = try TestSupport.directory("lha-header-reemit")
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
                let expected = try LHARecords.Entry(name: new.2.entries[entry.index].name, mode: ArchiveRepresentability.mode(for: entry), size: entry.uncompressedSize ?? 0, date: entry.modificationDate ?? TestSupport.date)
                    .header(method: a.method, packedSize: UInt32(a.dataRange.count), crc: a.method == "-lhd-" ? 0 : a.crc16)
                XCTAssertEqual(try LHAUpdateSupport.bytes(new.1, b.headerRange), expected, name)
                XCTAssertEqual(try LHAUpdateSupport.bytes(old.1, a.dataRange), try LHAUpdateSupport.bytes(new.1, b.dataRange), name)
                XCTAssertEqual(try LHAUpdateSupport.digest(old.2, entry.index), try LHAUpdateSupport.digest(new.2, entry.index), name)
                XCTAssertEqual(b.headerLevel, 2); XCTAssertEqual(b.osID, 0x55)
            }
        }
    }
}
