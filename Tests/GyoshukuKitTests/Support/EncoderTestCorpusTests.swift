import Foundation
import XCTest

final class EncoderTestCorpusTests: XCTestCase {
    func testBulkRandomRetainsOriginalBytesAndMasks() {
        for count in [0, 1, 7, 65_537] {
            for mask: UInt8 in [255, 31, 7] {
                var state: UInt64 = 0xD137_923A_6E25_9B41
                var expected = [UInt8]()
                for _ in 0..<count {
                    state ^= state >> 12; state ^= state << 25; state ^= state >> 27
                    expected.append(UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56) & mask)
                }
                XCTAssertEqual(TestCorpus.random(count, alphabetMask: mask), Data(expected))
            }
        }
    }

    func testTableCRCRetainsIndependentBitwiseOracle() {
        for bytes in [Data(), Data("123456789".utf8), TestCorpus.random(65_537)] {
            var value = UInt32.max
            for byte in bytes {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ ((0 &- (value & 1)) & 0xEDB8_8320) }
            }
            XCTAssertEqual(PPMdTestArchives.crc(bytes), ~value)
        }
    }
}
