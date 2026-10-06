import Foundation
import XCTest
@testable import GyoshukuKit

final class LZ4XXH32Tests: XCTestCase {
    func testKnownVectorsAtStripeAndWriteBoundaries() {
        // 独立 oracle: KaitoKit Tests/Fixtures/lz4-frame/manifest.json の lz4 1.10.0 checksum。
        // 入力 byte は (index * 73 + 19) & 255。値を固定し、製品実装から期待値を求めない。
        let vectors: [(Int, UInt32)] = [
            (0, 0x02CC5D05), (1, 0xAD95251D), (3, 0x2416B032), (15, 0x99FADAC8),
            (16, 0xCCF6227C), (17, 0x9F7A49D7), (31, 0xBD3D0A3A), (32, 0x5F483538),
            (33, 0xFD84D7E7), (255, 0x99308DB8), (65_536, 0xA41AC475), (65_539, 0xBF3E2A50),
        ]
        for (length, expected) in vectors {
            // slice の startIndex が 0 とは限らない。
            let backing = Data([0, 0, 0]) + Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
            let input = backing.dropFirst(3)
            XCTAssertEqual(XXH32.digest(input), expected, "length \(length)")
            for size in [1, 3, 15, 16, 17, 31, 4_093, 65_539] {
                var hash = XXH32()
                for start in stride(from: input.startIndex, to: input.endIndex, by: size) {
                    hash.update(input[start..<min(start + size, input.endIndex)])
                    let snapshot = hash.value
                    hash.update(Data())
                    XCTAssertEqual(hash.value, snapshot)
                }
                XCTAssertEqual(hash.value, expected, "length \(length), chunk \(size)")
            }
        }
        XCTAssertEqual(XXH32.digest(Data("a".utf8)), 0x550D7456)
        XCTAssertEqual(XXH32.digest(Data("abc".utf8)), 0x32D153FF)
        XCTAssertEqual(XXH32.digest(Data(), seed: 1), 0x0B2CB792)
    }
}
