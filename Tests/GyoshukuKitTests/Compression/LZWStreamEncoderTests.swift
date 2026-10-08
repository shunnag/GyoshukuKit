import Foundation
import XCTest
@testable import GyoshukuKit

final class LZWStreamEncoderTests: XCTestCase {
    func testVariableWidthsClearAndRealCompressCompatibility() throws { try verifyWidthsAndClear(large: false) }

    func testVariableWidthsClearAndRealCompressCompatibilityFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyWidthsAndClear(large: true)
    }

    private func verifyWidthsAndClear(large: Bool) throws {
        let directory = try TestSupport.directory("lzw-stream-encoder")
        // text → random → text: 辞書を満杯にした後で圧縮率を下げ、CLEAR と再学習を必ず通す。
        // 16-bit 辞書も 256 KiB 乱数で満杯になる。CLEAR 後の text も復号する。
        let text = large ? TestCorpus.pseudoSource(mebibytes: 2) : EncoderTestCorpus.shortSource
        let mixed = text + (large ? TestCorpus.random(3 << 20) : EncoderTestCorpus.random256KiB) + text
        let samples = (large ? StreamEncoderTestSupport.samples() : Self.smallSamples) + [(name: "clear", data: mixed)]
        for maxbits in [12, 16] {
            for sample in samples {
                let encoder = try LZWStreamEncoder(maxbits: maxbits)
                let encoded = try StreamEncoderTestSupport.encode(sample.data) { try encoder.write($0, finish: $1, emit: $2) }
                XCTAssertEqual(Array(encoded.prefix(3)), [0x1F, 0x9D, 0x80 | UInt8(maxbits)])
                if sample.name == "clear" { XCTAssertGreaterThan(encoder.clearCount, 0, "maxbits \(maxbits)") }
                let label = "\(sample.name)-bits\(maxbits)"
                let url = directory.appendingPathComponent(label + ".Z")
                try encoded.write(to: url)
                try StreamEncoderTestSupport.assertCompressCLI(url, input: sample.data, in: directory, label: label + "-decode")
                try StreamEncoderTestSupport.assertKaito(url, equals: sample.data)
                let plain = directory.appendingPathComponent(label + ".raw")
                try sample.data.write(to: plain)
                let oracle = try EncoderTestTiming.measure("reference.compress", input: sample.data.count) {
                    try StreamEncoderTestSupport.compressReference(plain, maxbits: maxbits, in: directory, label: label)
                }
                // BSD compress -f は空入力を 0 byte file にする（compress(1) BUGS）。
                if !sample.data.isEmpty { XCTAssertEqual(Array(oracle.prefix(3)), [0x1F, 0x9D, 0x80 | UInt8(maxbits)]) }
                // CLEAR の評価時点は実装ごとに異なる。byte 一致でなく実ツールとのサイズ比を見る。
                XCTAssertLessThanOrEqual(encoded.count, oracle.count * 5 / 4 + 32, label)
                XCTAssertGreaterThanOrEqual(encoded.count * 5 / 4 + 32, oracle.count, label)
                TestSupport.report("LZW_SIZE \(label) swift=\(encoded.count) compress=\(oracle.count) clears=\(encoder.clearCount)")
                try FileManager.default.removeItem(at: plain)
                try FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".reference.Z"))
                if sample.data.count > 1024 * 1024 { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    private static let smallSamples: [(name: String, data: Data)] = [
        ("empty", Data()), ("one", Data([0xA7])), ("zeros-64k", Data(repeating: 0, count: 65_536)),
        ("random", EncoderTestCorpus.random256KiB), ("text", EncoderTestCorpus.shortSource)
    ]

    func testEndOfFilePartialGroupsAndBytewiseWrites() throws {
        let directory = try TestSupport.directory("lzw-stream-groups")
        // 1〜8 literal は 9-bit の partial / full group を独立に確認できる。
        for count in 0...8 {
            let input = Data((0..<count).map(UInt8.init))
            let encoder = try LZWStreamEncoder()
            var encoded = Data()
            for byte in input { try encoder.write(Data([byte])) { encoded.append($0) } }
            try encoder.write(Data(), finish: true) { encoded.append($0) }
            XCTAssertEqual(encoded.count, 3 + (9 * count + 7) / 8)
            let url = directory.appendingPathComponent("group-\(count).Z")
            try encoded.write(to: url)
            try StreamEncoderTestSupport.assertCompressCLI(url, input: input, in: directory, label: "group-\(count)")
            try StreamEncoderTestSupport.assertKaito(url, equals: input)
        }
        let input = TestCorpus.random(65_537)
        for maxbits in [12, 16] {
            let encoder = try LZWStreamEncoder(maxbits: maxbits)
            var encoded = Data()
            try encoder.write(input, finish: true) { encoded.append($0) }
            let chunked = try LZWStreamEncoder(maxbits: maxbits)
            XCTAssertEqual(try StreamEncoderTestSupport.encode(input) { try chunked.write($0, finish: $1, emit: $2) }, encoded)
            let url = directory.appendingPathComponent("growth-\(maxbits).Z")
            try encoded.write(to: url)
            try StreamEncoderTestSupport.assertCompressCLI(url, input: input, in: directory, label: "growth-\(maxbits)")
            try StreamEncoderTestSupport.assertKaito(url, equals: input)
        }
    }

    func testInvalidMaxbitsAndTerminalStates() throws {
        for maxbits in [Int.min, 8, 9, 10, 11, 17, Int.max] {
            XCTAssertThrowsError(try LZWStreamEncoder(maxbits: maxbits)) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("compressMaxbits"))
            }
        }
        let encoder = try LZWStreamEncoder()
        try encoder.write(Data(), finish: true) { _ in }
        XCTAssertThrowsError(try encoder.write(Data([1]), finish: true) { _ in }) {
            XCTAssertEqual($0 as? WriterError, .invalidState)
        }
        let failed = try LZWStreamEncoder()
        XCTAssertThrowsError(try failed.write(Data([1]), finish: true) { _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try failed.write(Data(), finish: true) { _ in })
    }
}
