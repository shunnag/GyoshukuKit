import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarLargeOffsetTests: XCTestCase {
    func testLargeCRCAndImageOffsets() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_TESTS")
        let zeros = Data(count: 1024 * 1024), prefix = Data("prefix".utf8)
        var suffixCRC: UInt32 = 0, direct = updateCRC(0, prefix)
        for _ in 0..<4608 { suffixCRC = updateCRC(suffixCRC, zeros); direct = updateCRC(direct, zeros) }
        let length: UInt64 = 4608 * 1024 * 1024
        XCTAssertEqual(GzipFraming.combineCRC(updateCRC(0, prefix), suffixCRC, length: length), direct)
        let footer = GzipFraming.trailer(crc: direct, imageLength: length)
        XCTAssertEqual(footer.le32(4), 512 * 1024 * 1024)
        let unpadded = (UInt64(1) << 32) + 9, unpacked = (UInt64(1) << 32) + 513
        let record = XZFraming.vli(unpadded) + XZFraming.vli(unpacked)
        XCTAssertEqual(record, Data([0x89, 0x80, 0x80, 0x80, 0x10, 0x81, 0x84, 0x80, 0x80, 0x10]))
        var framed = Data()
        try XZFraming.emitIndexAndFooter(records: record, blockCount: 1) { framed.append($0) }
        XCTAssertEqual(framed[2..<(2 + record.count)], record)
        let source = LargePatternSource(length: length)
        let offset = (UInt64(1) << 32) + 127
        let image = TarImageSource(spans: [.init(source: source, offset: offset, range: 0..<4096, isOld: true)], length: 4096, terminalStart: 4096)
        let actual = try TarLayout.bytes(image, at: 0, count: 4096)
        XCTAssertEqual(actual, Data((0..<4096).map { UInt8((offset + UInt64($0)) % 251) }))
        TestSupport.report("TAR-LARGE length=\(length) crc=\(direct) offset=\(offset) passed")
    }
    private struct LargePatternSource: ByteSource {
        let length: UInt64
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let count = Int(min(UInt64(buffer.count), length - min(length, offset)))
            for index in 0..<count { buffer[index] = UInt8((offset + UInt64(index)) % 251) }
            return count
        }
    }
}
