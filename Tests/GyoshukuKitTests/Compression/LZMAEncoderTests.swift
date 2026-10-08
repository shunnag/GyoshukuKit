// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LZMAEncoderTests: XCTestCase {
    private let levels = [0, 1, 3, 5, 6, 9]

    func testWindowSlackCapacityAndMemoryAccounting() throws {
        for (dictionary, slack) in [(4096, 65536), (65536, 65536), (256 << 10, 128 << 10),
                                    (1 << 20, 512 << 10), (8 << 20, 4 << 20), (64 << 20, 4 << 20)] {
            var p = LZMAEncoderProperties.preset(6)
            p.dictSize = dictionary
            let current = LZMAEncodingEngine.memorySize(properties: p, dictionary: dictionary)
            let legacy = LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                LZMAEncodingEngine.memorySize(properties: p, dictionary: dictionary)
            }
            XCTAssertEqual(LZMAEncodingEngine.windowSlack(dictionary: dictionary), slack)
            XCTAssertEqual(current - legacy, slack - 65536)
            // chunked の旧固定容量と全見積りは test hook にも左右されない。
            let chunked = LZMAEncodingEngine.memorySize(properties: p, dictionary: dictionary, chunked: true)
            XCTAssertEqual(LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                LZMAEncodingEngine.memorySize(properties: p, dictionary: dictionary, chunked: true)
            }, chunked)
        }
        var p = LZMAEncoderProperties.preset(6)
        p.dictSize = 256 << 10
        let required = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize)
        for chunked in [false, true] {
            let memory = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize, chunked: chunked)
            let engine = try LZMAEncodingEngine(properties: p, sizeHint: nil, memoryLimit: memory, chunked: chunked)
            defer { engine.release() }
            XCTAssertEqual(engine.capacity, p.dictSize + (chunked ? 2 << 20 : 128 << 10) + 4369 + 65536)
            XCTAssertEqual(engine.rc.bufferLimit, 131072)
        }
        XCTAssertThrowsError(try LZMAEncoder(properties: p, memoryLimit: required - 1))
    }

    func testRawWindowSlackPreservesBytesAcrossCompactions() throws {
        let dictionary = 256 << 10
        // 辞書距離の再出現と圧縮しにくい末尾を含め、新旧とも複数回 compact する。
        let block = TestCorpus.random(dictionary / 2) + LZMAEncoderCorpus.text(size: dictionary / 2)
        let input = block + block + block + TestCorpus.random(65537)
        XCTAssertGreaterThan(input.count, 2 * dictionary)
        for level in [1, 6] {
            var p = LZMAEncoderProperties.preset(level)
            p.dictSize = dictionary
            for width in [1, 7, 65537, 262144] {
                let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                    try encodePieces(input, properties: p, width: width)
                }
                XCTAssertEqual(try encodePieces(input, properties: p, width: width), legacy,
                               "level \(level), width \(width)")
            }
        }
    }

    func testRawWindowSlackPreservesBytesWithLargeDictionaries() throws {
        let input = LZMAEncoderCorpus.text(size: (768 << 10) + 17)
        for level in [4, 6, 9] {
            let p = LZMAEncoderProperties.preset(level)
            for width in [65537, 262144] {
                // サイズ未知にして preset の完全な辞書と slack 上限も使う。
                let legacy = try LZMAEncodingEngine.$testingLegacyRawWindowSlack.withValue(true) {
                    try encodePieces(input, properties: p, width: width, knownSize: false)
                }
                XCTAssertEqual(try encodePieces(input, properties: p, width: width, knownSize: false), legacy,
                               "level \(level), width \(width)")
            }
        }
    }

    private func encodePieces(_ input: Data, properties: LZMAEncoderProperties, width: Int,
                              knownSize: Bool = true) throws -> Data {
        let encoder = try LZMAEncoder(properties: properties, expectedSize: knownSize ? UInt64(input.count) : nil)
        var output = Data()
        for start in stride(from: 0, to: input.count, by: width) {
            output.append(try encoder.push(input[start..<min(start + width, input.count)]))
        }
        output.append(try encoder.finish())
        return output
    }

    func testWordMatchLengthAtUnalignedBoundaries() {
        var bytes = [UInt8](repeating: 0xA7, count: 640)
        for mismatch in [0, 1, 7, 8, 15, 16, 63, 127, 272, 273] {
            bytes[320 + mismatch] = 0x19
            bytes.withUnsafeBufferPointer { buffer in
                for offset in 0..<8 {
                    let a = buffer.baseAddress! + offset, b = buffer.baseAddress! + 320 + offset
                    for limit in [0, 1, 7, 8, 9, 16, 64, 128, 273] {
                        for start in [0, min(3, limit), limit] {
                            var expected = start
                            while expected < limit && a[expected] == b[expected] { expected += 1 }
                            XCTAssertEqual(lzmaMatchLength(a, b, start: start, limit: limit), expected)
                            XCTAssertEqual(lzmaMatchLength(a, b, start: start, limit: limit, checkFirstByte: false), expected)
                        }
                    }
                }
            }
            bytes[320 + mismatch] = 0xA7
        }
        bytes.withUnsafeBufferPointer { buffer in
            for distance in 1...31 {
                XCTAssertEqual(lzmaMatchLength(buffer.baseAddress! + distance, buffer.baseAddress!, limit: 273), 273)
            }
        }
    }

    func testFinderPositionNormalizationPreservesStream() throws {
        let input = LZMAEncoderCorpus.mixed(size: 8192 + 777)
        for level in [1, 6] {
            var p = LZMAEncoderProperties.preset(level)
            p.dictSize = 4096
            func encode(normalizing: Bool) throws -> Data {
                var engine = try LZMAEncodingEngine(properties: p, sizeHint: UInt64(input.count), memoryLimit: 4 << 20)
                defer { engine.release() }
                input.withUnsafeBytes { bytes in
                    engine.window.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
                }
                engine.end = input.count
                engine.process(limit: 4096, reserve: 0)
                if normalizing {
                    // 履歴の相対距離を保ち、128位置後に UInt32 の正規化を起こす。
                    let shift = UInt32.max - 65536 - 128 - engine.finder.position
                    for i in 0..<engine.finder.hashCount where engine.finder.hash[i] != 0 { engine.finder.hash[i] += shift }
                    for i in 0..<(engine.finder.cyclicSize * (engine.finder.tree ? 2 : 1)) where engine.finder.son[i] != 0 {
                        engine.finder.son[i] += shift
                    }
                    engine.finder.position += shift
                }
                engine.process(limit: engine.end, reserve: 0)
                if normalizing { XCTAssertLessThan(engine.finder.position, 1 << 20) }
                engine.writeEndMarker(); engine.rc.finish()
                return engine.rc.take()
            }
            let expected = try encode(normalizing: false), normalized = try encode(normalizing: true)
            XCTAssertEqual(normalized, expected)
            XCTAssertEqual(try decodeRaw(normalized, properties: p, size: nil), input)
        }
    }

    func testExpandedBitPricesKeepOriginalQuantization() throws {
        // 展開前の SDK 1/16 bit 表を凍結し、全確率と両 bit の lookup を照合する。
        let original = [
            128, 103, 91, 84, 78, 73, 69, 66, 63, 61, 58, 56, 54, 52, 51, 49,
            48, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 34, 33,
            32, 31, 31, 30, 29, 29, 28, 28, 27, 26, 26, 25, 25, 24, 24, 23,
            23, 22, 22, 22, 21, 21, 20, 20, 19, 19, 19, 18, 18, 17, 17, 17,
            16, 16, 16, 15, 15, 15, 14, 14, 14, 13, 13, 13, 12, 12, 12, 11,
            11, 11, 11, 10, 10, 10, 10, 9, 9, 9, 9, 8, 8, 8, 8, 7,
            7, 7, 7, 6, 6, 6, 6, 5, 5, 5, 5, 5, 4, 4, 4, 4,
            3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
        ]
        let engine = try LZMAEncodingEngine(properties: .preset(6), sizeHint: 4096, memoryLimit: 4 << 20)
        defer { engine.release() }
        for probability in 1...2047 {
            for bit in 0...1 {
                XCTAssertEqual(engine.price(UInt16(probability), bit), original[(probability ^ (bit * 2047)) >> 4])
            }
        }
    }

    func testCachedPricesEqualBitTreePrices() throws {
        for niceLen in [5, 9, 16, 17, 18, 32, 64, 192, 273] {
            var p = LZMAEncoderProperties.preset(6)
            p.niceLen = niceLen; p.pb = 4
            var engine = try LZMAEncodingEngine(properties: p, sizeHint: 4096, memoryLimit: 4 << 20)
            defer { engine.release() }
            for i in 0..<engine.probCount { engine.probs[i] = UInt16(1 + (i * 131 + niceLen * 17) % 2047) }
            engine.updatePrices(lengths: true, repetitions: true, distances: true)
            for (offset, table) in [(LZMAEncodingEngine.lenOffset, engine.lengthPrices),
                                    (LZMAEncodingEngine.repLenOffset, engine.repLengthPrices)] {
                let probabilities = engine.probs + offset
                for pos in 0..<16 {
                    for sym in 0..<(niceLen - 1) {
                        let expected: Int
                        if sym < 8 {
                            expected = engine.price(probabilities[0], 0)
                                + engine.treePrice(probabilities + 2 + pos * 8, bits: 3, symbol: sym)
                        } else if sym < 16 {
                            expected = engine.price(probabilities[0], 1) + engine.price(probabilities[1], 0)
                                + engine.treePrice(probabilities + 130 + pos * 8, bits: 3, symbol: sym - 8)
                        } else {
                            expected = engine.price(probabilities[0], 1) + engine.price(probabilities[1], 1)
                                + engine.treePrice(probabilities + 258, bits: 8, symbol: sym - 16)
                        }
                        XCTAssertEqual(table[pos * 272 + sym], expected)
                    }
                }
            }
            for ls in 0..<4 {
                for distance in 0..<128 {
                    let slot = LZMAEncodingEngine.slot(distance)
                    var expected = engine.treePrice(engine.probs + 432 + ls * 64, bits: 6, symbol: slot)
                    if slot >= 4 {
                        let bits = (slot >> 1) - 1, base = (2 | (slot & 1)) << bits
                        expected += engine.treePrice(engine.probs + 688 + base - slot - 1, bits: bits,
                                                     symbol: distance - base, reverse: true)
                    }
                    XCTAssertEqual(engine.distancePrices[ls * 128 + distance], expected)
                }
            }
        }
    }

    func testSmallInputsAndEndMarker() throws {
        for level in levels {
            for input in [Data(), Data([0xE7]), Data(repeating: 0, count: 65536), TestCorpus.random(12003, alphabetMask: 15)] {
                try roundTrip(input, level: level)
            }
        }
    }
    func testLargeCorporaAndChunkBoundaries() throws { try verifyCorpora(large: false) }

    func testLargeCorporaAndChunkBoundariesFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyCorpora(large: true)
    }

    private func verifyCorpora(large: Bool) throws {
        for sample in try (large ? Self.largeEncoded : Self.smallEncoded).get() where sample.name != "empty" {
            try roundTrip(sample)
        }
    }

    // text の EOS、有無の既知サイズ、LZMA2 を一度ずつ作り、reader と実ツールで同じ bytes を検査する。
    private struct EncodedSample: Sendable {
        let name: String
        let input: Data
        let level: Int
        let unknownAlone: Data
        let knownAlone: Data
        let two: Data
    }

    private static let smallEncoded = Result { try encodedSamples(large: false) }
    private static let largeEncoded = Result { try encodedSamples(large: true) }

    private static func encodedSamples(large: Bool) throws -> [EncodedSample] {
        // mixed の一周期は 2.625 MiB。1 MiB 超の距離と raw→compressed の reset を保持する。
        let inputs: [(String, Data)] = [
            ("empty", Data()), ("random", TestCorpus.random(large ? 1 << 20 : 65_537)),
            ("text", LZMAEncoderCorpus.text(size: large ? 4 << 20 : 65_537)),
            ("mixed", LZMAEncoderCorpus.mixed(size: large ? 20 << 20 : (2688 << 10) + 17))
        ]
        var result: [EncodedSample] = []
        for level in [0, 1, 3, 5, 6, 9] {
            let p = LZMAEncoderProperties.preset(level)
            for (name, input) in inputs {
                let unknown = try EncoderTestTiming.measure("encode.LZMAEncoder.alone", input: input.count) {
                    try LZMAEncoder.alone(input, properties: p, knownSize: false)
                }
                let known = try EncoderTestTiming.measure("encode.LZMAEncoder.alone", input: input.count) {
                    try LZMAEncoder.alone(input, properties: p, knownSize: true)
                }
                let two = try EncoderTestTiming.measure("encode.LZMA2Encoder.encode", input: input.count) {
                    try LZMA2Encoder.encode(input, properties: p)
                }
                result.append(.init(name: name, input: input, level: level, unknownAlone: unknown, knownAlone: known, two: two))
            }
        }
        return result
    }

    func testOddPiecesProduceIdenticalStreams() throws { try verifyOddPieces(large: false) }

    func testOddPiecesProduceIdenticalStreamsFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyOddPieces(large: true)
    }

    private func verifyOddPieces(large: Bool) throws {
        let input = LZMAEncoderCorpus.mixed(size: large ? (2 << 20) + 777 : 65_537)
        for level in [1, 6] {
            let p = LZMAEncoderProperties.preset(level)
            let raw = try EncoderTestTiming.measure("encode.LZMAEncoder.encode", input: input.count) { try LZMAEncoder.encode(input, properties: p) }
            let lzma2 = try EncoderTestTiming.measure("encode.LZMA2Encoder.encode", input: input.count) { try LZMA2Encoder.encode(input, properties: p) }
            for width in [1, 7, 65537] {
                let one = try LZMAEncoder(properties: p, expectedSize: UInt64(input.count))
                let two = try LZMA2Encoder(properties: p, expectedSize: UInt64(input.count))
                var a = Data(), b = Data()
                for start in stride(from: 0, to: input.count, by: width) {
                    let piece = input.subdata(in: start..<min(start + width, input.count))
                    a.append(try one.push(piece)); b.append(try two.push(piece))
                }
                a.append(try one.finish()); b.append(try two.finish())
                XCTAssertEqual(a, raw, "raw level \(level), width \(width)")
                XCTAssertEqual(b, lzma2, "LZMA2 level \(level), width \(width)")
                XCTAssertEqual(try decodeRaw(a, properties: p, size: nil), input)
                XCTAssertEqual(try decodeTwo(b, properties: p, size: input.count), input)
            }
        }
    }
    func testIndependentXZAndAloneOracles() throws { try verifyOracles(large: false) }

    func testIndependentXZAndAloneOraclesFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyOracles(large: true)
    }

    private func verifyOracles(large: Bool) throws {
        let directory = try TestSupport.directory("lzma-encoder-oracles")
        for sample in try (large ? Self.largeEncoded : Self.smallEncoded).get() {
            let input = sample.input, p = LZMAEncoderProperties.preset(sample.level)
            let container = try LZMAEncoderCorpus.xz(sample.two, input: input, properties: p)
            let stem = "\(sample.level)-\(sample.name)"
            let xzURL = directory.appendingPathComponent(stem + ".xz")
            try container.write(to: xzURL)
            try ReferenceTool.run(ReferenceTool.xz, ["-t", xzURL.path], in: directory, log: stem + "-xz-test")
            let decoded = try ReferenceTool.run(ReferenceTool.xz, ["-dc", xzURL.path], in: directory,
                                                 log: stem + "-xz-decode", standardOutput: stem + ".decoded")
            XCTAssertEqual(decoded.bytes, input)
            try ReferenceTool.run(ReferenceTool.sevenZip, ["t", xzURL.path], in: directory, log: stem + "-7zz")
            for (known, alone) in [(false, sample.unknownAlone), (true, sample.knownAlone)] {
                let aloneURL = directory.appendingPathComponent(stem + "-\(known).lzma")
                try alone.write(to: aloneURL)
                let result = try ReferenceTool.run(ReferenceTool.xz, ["--format=lzma", "-dc", aloneURL.path],
                                                   in: directory, log: stem + "-alone-\(known)", standardOutput: stem + ".decoded")
                XCTAssertEqual(result.bytes, input)
                if result.status == 0 && result.bytes == input {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(stem + ".decoded"))
                }
            }
        }
    }

    func testTwoMiBChunkBoundaryWithOddPieces() throws {
        // 高圧縮入力なら packLimit より先に unpackLimit に届き、2 MiB と 17 byte の二 chunk を必ず作る。
        let input = Data(repeating: 0x5A, count: (2 << 20) + 17)
        for level in levels {
            let p = LZMAEncoderProperties.preset(level)
            let raw = try EncoderTestTiming.measure("encode.LZMAEncoder.encode", input: input.count) {
                try LZMAEncoder.encode(input, properties: p)
            }
            let expected = try EncoderTestTiming.measure("encode.LZMA2Encoder.encode", input: input.count) {
                try LZMA2Encoder.encode(input, properties: p)
            }
            XCTAssertEqual(try chunks(expected).map(\.size), [2 << 20, 17])
            for widths in [[65_537], [(2 << 20) - 8, 1, 7, 17]] {
                let one = try LZMAEncoder(properties: p, expectedSize: UInt64(input.count))
                let encoder = try LZMA2Encoder(properties: p, expectedSize: UInt64(input.count))
                var actualRaw = Data(), actual = Data(), offset = 0, index = 0
                while offset < input.count {
                    let end = min(offset + widths[index % widths.count], input.count)
                    actualRaw.append(try one.push(input[offset..<end]))
                    actual.append(try encoder.push(input[offset..<end]))
                    offset = end; index += 1
                }
                actualRaw.append(try one.finish())
                actual.append(try encoder.finish())
                XCTAssertEqual(actualRaw, raw)
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(try decodeRaw(actualRaw, properties: p, size: nil), input)
                XCTAssertEqual(try decodeTwo(actual, properties: p, size: input.count), input)
            }
        }
    }

    /// LZMA2 の独立した長さ検査。compressed / raw の payload は読み飛ばす。
    private func chunks(_ data: Data) throws -> [(control: UInt8, size: Int)] {
        var cursor = 0, result: [(control: UInt8, size: Int)] = []
        while cursor < data.count {
            let control = data[cursor]; cursor += 1
            if control == 0 { XCTAssertEqual(cursor, data.count); return result }
            guard cursor + 2 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            let size = (Int(data[cursor]) << 8) + Int(data[cursor + 1]) + 1
            cursor += 2
            if control < 0x80 {
                XCTAssertTrue(control == 1 || control == 2)
                result.append((control, size)); cursor += size
            } else {
                guard cursor + 2 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                let packed = (Int(data[cursor]) << 8) + Int(data[cursor + 1]) + 1
                result.append((control, (Int(control & 31) << 16) + size))
                cursor += 2 + (control >= 0xC0 ? 1 : 0) + packed
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    func testRangeOutputGrowthRetainsCarryAndHonorsBudget() throws {
        let input = TestCorpus.random(256 << 10)
        let p = LZMAEncoderProperties.preset(1)
        var engine = try LZMAEncodingEngine(properties: p, sizeHint: UInt64(input.count), memoryLimit: 32 << 20)
        defer { engine.release() }
        input.withUnsafeBytes { bytes in
            engine.window.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        engine.end = input.count
        // 中間 drain をせず range buffer を越える出力を作り、carry と probability が保たれることを復号で検査する。
        engine.process(limit: engine.end, reserve: 0)
        engine.writeEndMarker(); engine.rc.finish()
        XCTAssertNil(engine.rc.error)
        XCTAssertGreaterThan(engine.rc.capacity, 131072)
        XCTAssertEqual(try decodeRaw(engine.rc.take(), properties: p, size: nil), input)

        var limited = try LZMAEncodingEngine(properties: p, sizeHint: UInt64(input.count), memoryLimit: 32 << 20)
        defer { limited.release() }
        limited.rc.bufferLimit = limited.rc.capacity
        input.withUnsafeBytes { bytes in
            limited.window.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        limited.end = input.count
        limited.process(limit: limited.end, reserve: 0)
        guard case .memoryLimit = limited.rc.error else { return XCTFail("Range buffer must report its budget limit") }
    }

    func testUnknownSizeAndExtremeStreams() throws {
        let input = LZMAEncoderCorpus.mixed(size: (1 << 20) + 93001)
        let p = LZMAEncoderProperties.preset(0)
        let raw = try LZMAEncoder(properties: p)
        let two = try LZMA2Encoder(properties: p)
        var a = Data(), b = Data()
        for start in stride(from: 0, to: input.count, by: 65537) {
            let piece = input.subdata(in: start..<min(start + 65537, input.count))
            a.append(try raw.push(piece)); b.append(try two.push(piece))
        }
        a.append(try raw.finish()); b.append(try two.finish())
        XCTAssertEqual(try decodeRaw(a, properties: p, size: nil), input)
        XCTAssertEqual(try decodeTwo(b, properties: p, size: nil), input)
        let small = TestCorpus.random(93001, alphabetMask: 7) + Data(repeating: 0, count: 7777)
        for level in [0, 3, 5, 9] {
            let extreme = LZMAEncoderProperties.preset(level, extreme: true)
            XCTAssertEqual(try decodeRaw(LZMAEncoder.encode(small, properties: extreme), properties: extreme, size: nil), small)
            XCTAssertEqual(try decodeTwo(LZMA2Encoder.encode(small, properties: extreme), properties: extreme, size: nil), small)
        }
    }

    func testPropertiesLimitsAndCustomContexts() throws {
        let dicts = [18, 20, 21, 22, 22, 23, 23, 24, 25, 26]
        for level in 0...9 {
            let p = LZMAEncoderProperties.preset(level)
            XCTAssertEqual(p.dictSize, 1 << dicts[level])
            XCTAssertEqual(p.mode, level < 4 ? .fast : .normal)
            XCTAssertEqual(p.matchFinder, level < 4 ? .hc4 : .bt4)
            let extreme = LZMAEncoderProperties.preset(level, extreme: true)
            XCTAssertEqual(extreme.niceLen, level == 3 || level == 5 ? 192 : 273)
            XCTAssertEqual(extreme.cutValue, level == 3 || level == 5 ? 112 : 512)
        }
        var p = LZMAEncoderProperties.preset(1)
        p.dictSize = 3 << 29
        XCTAssertThrowsError(try LZMAEncoder(properties: p, memoryLimit: 64 << 20))
        let small = try LZMAEncoder(properties: p, expectedSize: 1, endMarker: false)
        let bytes = try small.push(Data([42])) + small.finish()
        XCTAssertEqual(try decodeRaw(bytes, properties: p, size: 1), Data([42]))
        for (lc, lp, pb) in [(0, 0, 0), (2, 2, 4), (8, 0, 1)] {
            p = .preset(6); p.lc = lc; p.lp = lp; p.pb = pb
            let input = TestCorpus.random(8000, alphabetMask: 15)
            XCTAssertEqual(try decodeRaw(LZMAEncoder.encode(input, properties: p), properties: p, size: nil), input)
            if lc + lp <= 4 { XCTAssertEqual(try decodeTwo(LZMA2Encoder.encode(input, properties: p), properties: p, size: nil), input) }
            else { XCTAssertThrowsError(try LZMA2Encoder(properties: p)) }
        }
        let encoder = try LZMAEncoder(expectedSize: 1)
        XCTAssertThrowsError(try encoder.finish())
        _ = try encoder.push(Data([0])); _ = try encoder.finish()
        XCTAssertThrowsError(try encoder.push(Data()))
        XCTAssertThrowsError(try encoder.finish())
    }
    private func roundTrip(_ input: Data, level: Int) throws {
        let p = LZMAEncoderProperties.preset(level)
        let raw = try EncoderTestTiming.measure("encode.LZMAEncoder.encode", input: input.count) { try LZMAEncoder.encode(input, properties: p) }
        XCTAssertEqual(try decodeRaw(raw, properties: p, size: nil), input, "raw level \(level)")
        let known = try EncoderTestTiming.measure("encode.LZMAEncoder.encode", input: input.count) { try LZMAEncoder.encode(input, properties: p, endMarker: false) }
        XCTAssertEqual(try decodeRaw(known, properties: p, size: input.count), input, "known level \(level)")
        let two = try EncoderTestTiming.measure("encode.LZMA2Encoder.encode", input: input.count) { try LZMA2Encoder.encode(input, properties: p) }
        XCTAssertEqual(try decodeTwo(two, properties: p, size: input.count), input, "LZMA2 level \(level)")
    }
    private func roundTrip(_ sample: EncodedSample) throws {
        let p = LZMAEncoderProperties.preset(sample.level)
        XCTAssertEqual(try decodeRaw(Data(sample.unknownAlone.dropFirst(13)), properties: p, size: nil), sample.input)
        XCTAssertEqual(try decodeRaw(Data(sample.knownAlone.dropFirst(13)), properties: p, size: sample.input.count), sample.input)
        XCTAssertEqual(try decodeTwo(sample.two, properties: p, size: sample.input.count), sample.input)
        if sample.name == "mixed" {
            let parts = try chunks(sample.two)
            XCTAssertTrue(parts.contains { $0.control < 0x80 })
            XCTAssertTrue(parts.contains { $0.control >= 0x80 })
            // copy chunk の直後に LZMA chunk があることを wire で確認する。
            XCTAssertTrue(zip(parts, parts.dropFirst()).contains { $0.0.control < 0x80 && $0.1.control >= 0x80 })
        }
    }

    private func decodeRaw(_ bytes: Data, properties p: LZMAEncoderProperties, size: Int?) throws -> Data {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("decode.lzma-raw", phaseStart, input: bytes.count) }
        let decoder = try LZMADecoder(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count),
                                     properties: Array(p.bytes), expectedSize: size.map(UInt64.init), dictionarySizeLimit: UInt64(3 << 29))
        return try read(decoder)
    }
    private func decodeTwo(_ bytes: Data, properties p: LZMAEncoderProperties, size: Int?) throws -> Data {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("decode.lzma2", phaseStart, input: bytes.count) }
        let decoder = try LZMA2Decoder(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count),
                                     properties: [LZMA2Encoder.dictionaryProperty(for: p.dictSize)],
                                     expectedSize: size.map(UInt64.init), dictionarySizeLimit: UInt64(3 << 29))
        return try read(decoder)
    }
    private func read(_ decoder: any Decompressor) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65537)
        var appendTime: UInt64 = 0
        defer { EncoderTestTiming.duration("test.decode-append", appendTime, output: output.count) }
        while true {
            let n = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if n == 0 { break }
            guard n > 0 && n <= buffer.count else { throw CocoaError(.fileReadCorruptFile) }
            let start = EncoderTestTiming.start()
            buffer.withUnsafeBytes { output.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n) }
            if EncoderTestTiming.enabled { appendTime += DispatchTime.now().uptimeNanoseconds - start }
        }
        return output
    }
}
