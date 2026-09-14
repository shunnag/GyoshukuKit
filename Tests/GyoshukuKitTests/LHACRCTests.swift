import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

@MainActor
final class LHACRCTests: XCTestCase {
    func testARCCheckVectorAndIncrementalCRC() {
        let vector = Data("123456789".utf8)
        XCTAssertEqual(LHACRC16.update(0, vector), 0xBB3D)
        XCTAssertEqual(LHACRC16.update(0, Data()), 0)
        let data = LHATestSupport.random(65_537)
        let first = LHACRC16.update(0, data.prefix(4097))
        XCTAssertEqual(LHACRC16.update(first, data.dropFirst(4097)), LHATestSupport.crc(data))
    }

    func testHeaderCRCValueAndCorruptionRejectedByKaito() throws {
        let directory = try ZipTestSupport.directory("lha-header-crc")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        let payload = Data("header CRC fixture".utf8)
        try writer.add(data: payload, as: "ascii.txt", modificationDate: ZipTestSupport.date)
        try writer.finish()
        var data = try Data(contentsOf: url)
        let member = try XCTUnwrap(LHABytes(data).members.first)
        // table を使わない bitwise CRC で、二つの CRC byte をゼロにした header 全体を再計算する。
        var header = member.header
        header[member.crcOffset] = 0
        header[member.crcOffset + 1] = 0
        XCTAssertEqual(LHATestSupport.uint16(member.header, member.crcOffset), LHATestSupport.crc(header))
        XCTAssertEqual(LHATestSupport.uint16(member.header, 21), LHATestSupport.crc(payload))
        try LHATestSupport.verify(url, expected: [.init(name: "ascii.txt", data: payload)])
        data[member.crcOffset] ^= 1
        let corrupt = directory.appendingPathComponent("header-crc.lzh")
        try data.write(to: corrupt)
        XCTAssertThrowsError(try ArchiveReader.open(url: corrupt)) { error in
            guard case KaitoError.malformed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "LHA header CRC mismatch")
        }
        // 実機で確認: 7zz 26.03 は header CRC を検査せず Everything is Ok とする。
        // Lhasa 0.6.0 の lha t はこの member を読まず、出力なし・終了値 0 で戻る。
        // どちらの挙動も CRC の検証 assertion には使わず、上の独立計算と KaitoKit に担わせる。
        try LHATestSupport.run(LHATestSupport.lhasa, ["t", corrupt.path], in: directory, log: "lha-header-crc-observation")
        try LHATestSupport.run(LHATestSupport.sevenZip, ["t", corrupt.path], in: directory, log: "7zz-header-crc-observation")
    }

    func testDataCRCCorruptionReportsDamagedMemberInBothTools() throws {
        let directory = try ZipTestSupport.directory("lha-data-crc")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        let payload = Data(repeating: 0x61, count: 4096)
        try writer.add(data: payload, as: "damaged.txt", modificationDate: ZipTestSupport.date)
        try writer.add(data: Data("unaffected".utf8), as: "intact.txt", modificationDate: ZipTestSupport.date)
        try writer.finish()
        var data = try Data(contentsOf: url)
        let member = try XCTUnwrap(LHABytes(data).members.first)
        XCTAssertEqual(member.method, "-lh5-")
        data[21] ^= 1
        // data CRC 欄も header CRC の範囲。外側を修復し、data の照合だけを失敗させる。
        data[member.crcOffset] = 0
        data[member.crcOffset + 1] = 0
        let headerCRC = LHATestSupport.crc(data.prefix(member.header.count))
        data[member.crcOffset] = UInt8(truncatingIfNeeded: headerCRC)
        data[member.crcOffset + 1] = UInt8(headerCRC >> 8)
        try data.write(to: url)
        let lhasa = try LHATestSupport.run(LHATestSupport.lhasa, ["t", url.path], in: directory, log: "lha-data-crc")
        XCTAssertTrue(lhasa.text.contains("damaged.txt\t- CRC error"), lhasa.text)
        XCTAssertTrue(lhasa.text.contains("intact.txt\t- Tested"), lhasa.text)
        let seven = try LHATestSupport.run(LHATestSupport.sevenZip, ["t", url.path], in: directory, log: "7zz-data-crc")
        XCTAssertTrue(seven.text.contains("ERROR: CRC Failed : damaged.txt"), seven.text)
        XCTAssertFalse(seven.text.contains("Everything is Ok"), seven.text)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertThrowsError(try reader.read(reader.entries[0]))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data("unaffected".utf8))
    }
}
