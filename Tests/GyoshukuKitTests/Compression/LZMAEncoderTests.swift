// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LZMAEncoderTests: XCTestCase {
    private let levels = [0, 1, 3, 5, 6, 9]

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
            // raw の後の compressed は model reset を宣言する。
            XCTAssertTrue(zip(parts, parts.dropFirst()).contains { $0.0.control < 0x80 && $0.1.control >= 0xA0 })
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
