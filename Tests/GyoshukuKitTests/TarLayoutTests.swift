import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class TarLayoutTests: XCTestCase {
    func testSignedChecksumAndNumericFields() throws {
        var header = TarRecords.Entry(name: Data("name".utf8), size: 9 * 1024 * 1024 * 1024).ustar()
        header[265] = 0xff
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let signed = header.reduce(Int64(0)) { $0 + Int64(Int8(bitPattern: $1)) }
        TarRecords.number(UInt64(signed), in: &header, at: 148, width: 7)
        header[155] = 32
        XCTAssertNoThrow(try TarLayout.validateChecksum(header))
        XCTAssertEqual(try TarLayout.number(header, range: 124..<136), 9 * 1024 * 1024 * 1024)
        XCTAssertEqual(try TarLayout.number(Data("  17\0  ".utf8)), 15)
        XCTAssertThrowsError(try TarLayout.number(Data("1 7".utf8)))
        XCTAssertThrowsError(try TarLayout.number(Data([0xff, 0, 1])))
        header[0] ^= 1
        XCTAssertThrowsError(try TarLayout.validateChecksum(header))
    }

    func testGenericByteSourceUnitsAndBoundedHeaderReads() throws {
        let root = try TestSupport.directory("p2-layout")
        let source = try TarEditTestSupport.fixture(root, count: 20, size: 64 * 1024)
        let data = try Data(contentsOf: source)
        let (_, disk, reader) = try TarEditTestSupport.scan(source)
        let reads = ZipIOEvents()
        let layout = try ZipUpdateSource.$readObserver.withValue(reads.read) {
            try TarLayout.scan(source: disk, length: disk.length, entries: reader.entries, nameEncoding: reader.nameEncoding,
                               hardLinkTargets: [:], dataTargets: [:])
        }
        XCTAssertEqual(layout.units.count, 20)
        XCTAssertLessThanOrEqual(MemoryLayout<TarLayout.Unit>.stride, 48)
        XCTAssertTrue(reads.events.allSatisfy { $0.count <= 4096 && ($0.offset % (65536 + 512) == 0) })
        let memory = try TarLayout.scan(source: TarMemorySource(data: data), length: UInt64(data.count), entries: reader.entries,
                                       nameEncoding: nil, hardLinkTargets: [:], dataTargets: [:])
        XCTAssertEqual(memory.membersEnd, layout.membersEnd)
        XCTAssertEqual(memory.units.map(\.groupStart), layout.units.map(\.groupStart))
    }
}
