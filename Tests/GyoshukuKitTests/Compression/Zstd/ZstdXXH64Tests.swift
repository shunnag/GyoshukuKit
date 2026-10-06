// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation
import XCTest
@testable import GyoshukuKit

final class ZstdXXH64Tests: XCTestCase {
    func testKnownVectors() {
        let vectors: [(String, UInt64)] = [("",0xEF46DB3751D8E999), ("a",0xD24EC4F1A98C6E5B),
            ("abc",0x44BC2CF5AD770999), ("message digest",0x066ED728FCEEB3BE),
            ("abcdefghijklmnopqrstuvwxyz",0xCFE1F278FA89835C),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",0xAAA46907D3047814),
            (String(repeating: "1234567890", count: 8),0xE04A477F19EE145D)]
        for (input, expected) in vectors {
            var hash = ZstdXXH64(); hash.update(Data(input.utf8))
            XCTAssertEqual(hash.digest(), expected, input)
        }
    }
    func testStreamingStripesSlicesAndSeeds() {
        let input = TestCorpus.random(65_537)
        for seed: UInt64 in [0,1,UInt64.max] {
            var whole = ZstdXXH64(seed: seed); whole.update(input)
            for chunk in [1,7,31,32,33,65,2049] {
                var hash = ZstdXXH64(seed: seed)
                for i in stride(from: 0, to: input.count, by: chunk) {
                    hash.update(input[i..<min(i + chunk, input.count)])
                    _ = hash.digest() // digest must not finalize the streaming state
                }
                XCTAssertEqual(hash.digest(), whole.digest())
            }
        }
    }
}
