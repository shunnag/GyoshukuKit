import Foundation
import XCTest
@testable import GyoshukuKit

/// 連続二位置を交互に走査する `treeMatchesPair` が、逐次の `matches` と同じ候補列と同じ hash / son を作ることを検査する。
/// 辞書を 4096 に縮め、後の位置の slot が前の位置から見える最古の node と重なる場合を多く作る。
final class LZMAPairedFinderTests: XCTestCase {
    private func corpus() -> Data {
        let text = LZMAEncoderCorpus.text(size: 12288)
        var input = text + TestCorpus.random(4096) + Data(repeating: 65, count: 4096) + text.prefix(6001)
        input += TestCorpus.random(2048, alphabetMask: 3) + text + Data(repeating: 0, count: 300) + text.suffix(5000)
        return input
    }

    private func assertSame(_ expected: UnsafeMutablePointer<LZMAMatch>, _ n: Int,
                            _ actual: UnsafeMutablePointer<LZMAMatch>, _ m: Int, _ context: String) {
        XCTAssertEqual(n, m, context)
        guard n == m else { return }
        for i in 0..<n {
            XCTAssertEqual(expected[i].length, actual[i].length, "\(context) [\(i)]")
            XCTAssertEqual(expected[i].distance, actual[i].distance, "\(context) [\(i)]")
        }
    }

    func testPairedTreeWalkMatchesSequentialCandidatesAndTables() throws {
        let input = corpus()
        let a = try lzmaAllocate(LZMAMatch.self, count: 274)
        let b = try lzmaAllocate(LZMAMatch.self, count: 274)
        let c = try lzmaAllocate(LZMAMatch.self, count: 274)
        defer { free(a); free(b); free(c) }
        for level in 4...9 {
            for extreme in [false, true] {
                for (dictionary, recordShort, extend) in [(4096, true, true), (4096, false, false), (1 << 20, true, false), (8192, true, true)] {
                    var properties = LZMAEncoderProperties.preset(level, extreme: extreme)
                    properties.dictSize = dictionary
                    var sequential = try LZMAMatchFinder(properties: properties, dictionary: dictionary)
                    var paired = try LZMAMatchFinder(properties: properties, dictionary: dictionary)
                    defer { sequential.release(); paired.release() }
                    XCTAssertTrue(paired.tree)
                    var pairs = 0, singles = 0
                    input.withUnsafeBytes { bytes in
                        let data = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        var position = 0
                        while position < input.count {
                            let available = input.count - position
                            // 可変長の skip と、末尾の available = 1...8 の対の不成立を含む。
                            let record = position % 97 < 61 || available < 12
                            let context = "level \(level)\(extreme ? "e" : "") dict \(dictionary) position \(position) record \(record)"
                            let n = sequential.matches(data + position, available: available, into: a, record: record,
                                                       extendMatches: extend, recordShortMatches: recordShort)
                            if position + 1 < input.count,
                               let (x, y) = paired.treeMatchesPair(data + position, available: available, into: b, second: c,
                                                                   record: record, extendMatches: extend, recordShortMatches: recordShort) {
                                if record { assertSame(a, n, b, x, context) }
                                let m = sequential.matches(data + position + 1, available: available - 1, into: a, record: record,
                                                           extendMatches: extend, recordShortMatches: recordShort)
                                if record { assertSame(a, m, c, y, context + " second") }
                                position += 2; pairs += 1
                            } else {
                                let m = paired.matches(data + position, available: available, into: b, record: record,
                                                       extendMatches: extend, recordShortMatches: recordShort)
                                if record { assertSame(a, n, b, m, context) }
                                position += 1; singles += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(pairs, input.count / 4, "level \(level) dict \(dictionary)")
                    XCTAssertGreaterThan(singles, 0, "level \(level) dict \(dictionary)")
                    XCTAssertEqual(sequential.position, paired.position)
                    XCTAssertEqual(sequential.cyclic, paired.cyclic)
                    XCTAssertEqual(memcmp(sequential.hash, paired.hash, sequential.hashCount * 4), 0, "hash level \(level) dict \(dictionary)")
                    XCTAssertEqual(memcmp(sequential.son, paired.son, sequential.cyclicSize * 8), 0, "son level \(level) dict \(dictionary)")
                }
            }
        }
    }

    func testHashChainPresetsNeverPair() throws {
        let input = LZMAEncoderCorpus.text(size: 4096)
        let a = try lzmaAllocate(LZMAMatch.self, count: 274)
        defer { free(a) }
        for level in 0...3 {
            var finder = try LZMAMatchFinder(properties: .preset(level), dictionary: 4096)
            defer { finder.release() }
            XCTAssertFalse(finder.tree)
            input.withUnsafeBytes { bytes in
                let data = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                XCTAssertNil(finder.treeMatchesPair(data, available: input.count, into: a, second: a, record: true,
                                                    extendMatches: true, recordShortMatches: true))
            }
            XCTAssertEqual(finder.position, 1)
        }
    }

    /// parser 側の一位置 cache と skip の対は、push 幅・既知サイズ・finder thread 数に左右されない bytes を作る。
    func testPairedWalkCacheKeepsStreamsIdenticalAcrossPushWidths() throws {
        let input = LZMAEncoderCorpus.mixed(size: 300_000) + corpus()
        for level in [4, 6, 9] {
            let p = LZMAEncoderProperties.preset(level)
            let reference = try LZMAEncoder.encode(input, properties: p)
            for width in [1, 272, 273, 274, 4099, 65536, 65537] {
                for unknownSize in [false, true] {
                    let encoder = try LZMAEncoder(properties: p, expectedSize: unknownSize ? nil : UInt64(input.count))
                    var output = Data()
                    for start in stride(from: 0, to: input.count, by: width) {
                        output.append(try encoder.push(input.subdata(in: start..<min(input.count, start + width))))
                    }
                    output.append(try encoder.finish())
                    XCTAssertEqual(output, reference, "level \(level) width \(width) unknownSize \(unknownSize)")
                }
            }
            XCTAssertEqual(try LZMAEncoder.encode(input, properties: p, finderThreads: 2), reference, "level \(level) finder threads")
        }
    }

    /// LZMA2 の chunk 境界では finderCursor == cursor。packedLimit で止まると次位置の cache は残り得る。
    func testLZMA2ChunkBoundaryWithPairedWalk() throws {
        let input = LZMAEncoderCorpus.mixed(size: (2 << 20) + 4099)
        let p = LZMAEncoderProperties.preset(4)
        let reference = try LZMA2Encoder.encode(input, properties: p)
        let encoder = try LZMA2Encoder(properties: p, expectedSize: nil)
        var output = Data()
        for start in stride(from: 0, to: input.count, by: 4099) {
            output.append(try encoder.push(input.subdata(in: start..<min(input.count, start + 4099))))
        }
        output.append(try encoder.finish())
        XCTAssertEqual(output, reference)
    }
}
