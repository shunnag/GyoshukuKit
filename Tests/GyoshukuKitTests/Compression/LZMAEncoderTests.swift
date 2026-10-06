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
    func testLargeCorporaAndChunkBoundaries() throws {
        let random = TestCorpus.random(1 << 20)
        let text = LZMAEncoderCorpus.text(size: 4 << 20)
        let mixed = LZMAEncoderCorpus.mixed(size: 20 << 20)
        for level in levels {
            for (name, input) in [("random", random), ("text", text), ("mixed", mixed)] {
                TestSupport.report("LZMAEncoder round trip: level=\(level) corpus=\(name)")
                try roundTrip(input, level: level)
            }
        }
    }
    func testOddPiecesProduceIdenticalStreams() throws {
        let input = LZMAEncoderCorpus.mixed(size: (2 << 20) + 777)
        for level in [1, 6] {
            let p = LZMAEncoderProperties.preset(level)
            let raw = try LZMAEncoder.encode(input, properties: p)
            let lzma2 = try LZMA2Encoder.encode(input, properties: p)
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
    func testIndependentXZAndAloneOracles() throws {
        let directory = try TestSupport.directory("lzma-encoder-oracles")
        for level in levels {
            for (name, input) in [("empty", Data()), ("random", TestCorpus.random(1 << 20)),
                                  ("text", LZMAEncoderCorpus.text(size: 4 << 20)),
                                  ("mixed", LZMAEncoderCorpus.mixed(size: 20 << 20))] {
                let p = LZMAEncoderProperties.preset(level)
                let payload = try LZMA2Encoder.encode(input, properties: p)
                let container = try LZMAEncoderCorpus.xz(payload, input: input, properties: p)
                let stem = "\(level)-\(name)"
                let xzURL = directory.appendingPathComponent(stem + ".xz")
                try container.write(to: xzURL)
                try ReferenceTool.run(ReferenceTool.xz, ["-t", xzURL.path], in: directory, log: stem + "-xz-test")
                let decoded = try ReferenceTool.run(ReferenceTool.xz, ["-dc", xzURL.path], in: directory,
                                                     log: stem + "-xz-decode", standardOutput: stem + ".decoded")
                XCTAssertEqual(decoded.bytes, input)
                try ReferenceTool.run(ReferenceTool.sevenZip, ["t", xzURL.path], in: directory, log: stem + "-7zz")
                for known in [false, true] {
                    let aloneURL = directory.appendingPathComponent(stem + "-\(known).lzma")
                    try LZMAEncoder.alone(input, properties: p, knownSize: known).write(to: aloneURL)
                    let result = try ReferenceTool.run(ReferenceTool.xz, ["--format=lzma", "-dc", aloneURL.path],
                                                       in: directory, log: stem + "-alone-\(known)", standardOutput: stem + ".decoded")
                    XCTAssertEqual(result.bytes, input)
                    if result.status == 0 && result.bytes == input {
                        try FileManager.default.removeItem(at: directory.appendingPathComponent(stem + ".decoded"))
                    }
                }
            }
        }
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
        let raw = try LZMAEncoder.encode(input, properties: p)
        XCTAssertEqual(try decodeRaw(raw, properties: p, size: nil), input, "raw level \(level)")
        let known = try LZMAEncoder.encode(input, properties: p, endMarker: false)
        XCTAssertEqual(try decodeRaw(known, properties: p, size: input.count), input, "known level \(level)")
        let two = try LZMA2Encoder.encode(input, properties: p)
        XCTAssertEqual(try decodeTwo(two, properties: p, size: input.count), input, "LZMA2 level \(level)")
    }
    private func decodeRaw(_ bytes: Data, properties p: LZMAEncoderProperties, size: Int?) throws -> Data {
        let decoder = try LZMADecoder(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count),
                                     properties: Array(p.bytes), expectedSize: size.map(UInt64.init), dictionarySizeLimit: UInt64(3 << 29))
        return try read(decoder)
    }
    private func decodeTwo(_ bytes: Data, properties p: LZMAEncoderProperties, size: Int?) throws -> Data {
        let decoder = try LZMA2Decoder(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count),
                                     properties: [LZMA2Encoder.dictionaryProperty(for: p.dictSize)],
                                     expectedSize: size.map(UInt64.init), dictionarySizeLimit: UInt64(3 << 29))
        return try read(decoder)
    }
    private func read(_ decoder: any Decompressor) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65537)
        while true {
            let n = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if n == 0 { break }
            output.append(contentsOf: buffer.prefix(n))
        }
        return output
    }
}
