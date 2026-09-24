import Foundation
import XCTest
@testable import GyoshukuKit

final class DeflateBlockTests: XCTestCase {
    func testRandomBlocksFitBoundAtEveryLevelAndDictionarySize() throws {
        let random = LHATestSupport.random(DeflateBlock.size + 32 * 1024)
        for level in 0...9 {
            for count in [1, 31, 257, 16_383, 65_536, DeflateBlock.size] {
                for dictionarySize in [0, 32 * 1024] {
                    let input = Data(random.suffix(count))
                    for final in [false, true] {
                        let block = DeflateBlock(input: input, dictionary: Data(random.prefix(dictionarySize)), final: final)
                        let encoded = try DeflateBlock.encode(block, level: level)
                        XCTAssertLessThanOrEqual(UInt64(encoded.count), try DeflateBlock.bound(UInt64(count)))
                        if !final { XCTAssertEqual(Data(encoded.suffix(4)), Data([0, 0, 255, 255])) }
                    }
                }
            }
        }
    }

    func testRandomSmallBlocksReserveZIP64AtCompressedSizeThreshold() throws {
        let blockSize = 64
        let random = LHATestSupport.random(2 * blockSize)
        let a = Data(random.prefix(blockSize)), b = Data(random.suffix(blockSize))
        for level in [0, 6, 9] {
            func length(_ input: Data, dictionary: Data, final: Bool = false) throws -> UInt64 {
                UInt64(try DeflateBlock.encode(.init(input: input, dictionary: dictionary, final: final), level: level).count)
            }
            let first = try length(a, dictionary: Data())
            let last = try length(b, dictionary: a, final: true)
            let pair = try length(b, dictionary: a) + length(a, dictionary: b)
            // A/B を交互に置く実圧縮長。辞書は直前64 byteなので全反復で同じ結果になる。
            let repetitions = (ZipRecords.limit - first - last + pair - 1) / pair
            let size = UInt64(blockSize * 2) * (repetitions + 1)
            let packed = first + repetitions * pair + last
            XCTAssertLessThan(size, ZipRecords.limit)
            XCTAssertGreaterThanOrEqual(packed, ZipRecords.limit)
            let oldBound = size + (size >> 12) + (size >> 14) + (size >> 25) + 13
            XCTAssertLessThan(oldBound, ZipRecords.limit)
            let bound = try DeflateBlock.bound(size: size, blockSize: blockSize)
            XCTAssertGreaterThanOrEqual(bound, packed)
            var entry = ZipRecords.Entry(name: Data("random".utf8), method: .deflate, mtime: 0, atime: 0,
                dosTime: 0, dosDate: 0x21, mode: 0o100644, owners: nil, offset: 0, size: size)
            entry.reservedZIP64 = bound >= ZipRecords.limit
            let before = entry.local()
            XCTAssertNotNil(ZipBytes(data: before).extras(0, local: true)[0xFFFF])
            entry.compressedSize = packed
            let after = entry.local()
            XCTAssertEqual(before.count, after.count)
            XCTAssertEqual(ZipBytes(data: after).u32(18), UInt32.max)
            let extra = try XCTUnwrap(ZipBytes(data: after).extras(0, local: true)[1])
            XCTAssertEqual(ZipBytes(data: extra).u64(8), packed)
        }
        XCTAssertThrowsError(try DeflateBlock.bound(size: UInt64.max, blockSize: 1)) {
            XCTAssertEqual($0 as? WriterError, .sizeOverflow)
        }
    }

    func testGzipEmptyAndExactBlockBoundariesIgnoreWriteSizes() throws {
        let blockSize = 8192
        let input = LHATestSupport.random(2 * blockSize + 7)
        for count in [0, 1, blockSize, blockSize + 1, 2 * blockSize, input.count] {
            for level in [0, 1, 6, 9] {
                var expected: Data?
                for step in [113, blockSize, input.count] {
                    let compressor = try GzipCompressor(level: level, threads: 4, blockSize: blockSize)
                    var result = Data()
                    for offset in stride(from: 0, to: count, by: step) {
                        try compressor.write(input[offset..<min(offset + step, count)]) { result.append($0) }
                    }
                    try compressor.write(Data(), finish: true) { result.append($0) }
                    if let expected { XCTAssertEqual(result, expected) } else { expected = result }
                }
            }
        }
    }

    func testDictionaryIsUsedAcrossBlocks() throws {
        let dictionary = LHATestSupport.random(32 * 1024)
        let input = Data(dictionary.suffix(16 * 1024))
        for level in [6, 9] {
            let primed = try DeflateBlock.encode(.init(input: input, dictionary: dictionary, final: true), level: level)
            let independent = try DeflateBlock.encode(.init(input: input, dictionary: Data(), final: true), level: level)
            XCTAssertLessThan(primed.count * 20, independent.count)
        }
    }
}
