import Foundation
import XCTest
@testable import GyoshukuKit

final class LZ4FrameEncoderTests: XCTestCase {
    func testAllInputsSizeFlagsBlockChecksumsAndParallelBlocksWithRealDecoders() throws {
        let directory = try TestSupport.directory("lz4-frame-encoder")
        for sample in StreamEncoderTestSupport.samples() {
            for knownSize in [false, true] {
                for blockChecksums in [false, true] {
                    let encoder = try LZ4FrameEncoder(contentSize: knownSize ? UInt64(sample.data.count) : nil,
                                                      blockChecksums: blockChecksums, threads: 3)
                    let encoded = try StreamEncoderTestSupport.encode(sample.data) {
                        try encoder.write($0, finish: $1, emit: $2)
                        XCTAssertLessThanOrEqual(encoder.pendingInputBytes, 3 * UInt64(LZ4FrameEncoder.blockSize))
                    }
                    XCTAssertEqual(encoder.pendingInputBytes, 0)
                    let label = "\(sample.name)-size\(knownSize)-blockcrc\(blockChecksums)"
                    let url = directory.appendingPathComponent(label + ".lz4")
                    try encoded.write(to: url)
                    try ReferenceTool.run(StreamEncoderTestSupport.lz4, ["-t", url.path], in: directory, log: label + "-test")
                    try StreamEncoderTestSupport.assertCLI(StreamEncoderTestSupport.lz4, arguments: ["-dc"],
                                                          url: url, input: sample.data, in: directory, label: label + "-decode")
                    try StreamEncoderTestSupport.assertKaito(url, equals: sample.data)
                    // 仕様の byte 表を直接検査する。全入力は一つの frame、BD は常に 4 MiB。
                    XCTAssertEqual(encoded.le32(0), 0x184D2204)
                    XCTAssertEqual(encoded[4], 0x64 | (knownSize ? 8 : 0) | (blockChecksums ? 16 : 0))
                    XCTAssertEqual(encoded[5], 0x70)
                    if knownSize { XCTAssertEqual(encoded.le64(6), UInt64(sample.data.count)) }
                    var offset = knownSize ? 15 : 7, blocks = 0
                    while encoded.le32(offset) != 0 {
                        let word = encoded.le32(offset), count = Int(word & 0x7FFF_FFFF)
                        XCTAssertLessThanOrEqual(count, LZ4FrameEncoder.blockSize)
                        if sample.name == "random-9m" { XCTAssertNotEqual(word & 0x8000_0000, 0) }
                        if sample.name == "text-12m" { XCTAssertEqual(word & 0x8000_0000, 0) }
                        offset += 4 + count + (blockChecksums ? 4 : 0)
                        blocks += 1
                    }
                    XCTAssertEqual(blocks, (sample.data.count + LZ4FrameEncoder.blockSize - 1) / LZ4FrameEncoder.blockSize)
                    XCTAssertEqual(offset + 8, encoded.count)
                    if sample.data.count > 1024 * 1024 { try FileManager.default.removeItem(at: url) }
                }
            }
        }
    }

    func testParallelismAndInputBoundariesDoNotChangeTheFrame() throws {
        let input = TestCorpus.random(2 * LZ4FrameEncoder.blockSize + 7, alphabetMask: 15)
        let sequential = try LZ4FrameEncoder(contentSize: UInt64(input.count), blockChecksums: true, threads: 1)
        var expected = Data()
        try sequential.write(input, finish: true) { expected.append($0) }
        let parallel = try LZ4FrameEncoder(contentSize: UInt64(input.count), blockChecksums: true, threads: 4)
        let result = try StreamEncoderTestSupport.encode(input) { try parallel.write($0, finish: $1, emit: $2) }
        XCTAssertEqual(result, expected)
        XCTAssertThrowsError(try parallel.write(Data(), finish: true) { _ in }) {
            XCTAssertEqual($0 as? WriterError, .invalidState)
        }
    }

    func testDeclaredSizeValidationAndSinkFailureAreTerminal() throws {
        XCTAssertThrowsError(try LZ4FrameEncoder(threads: 0))
        XCTAssertThrowsError(try LZ4FrameEncoder(threads: 65))
        for input in [Data(), Data([1, 2])] {
            let encoder = try LZ4FrameEncoder(contentSize: 1, threads: 1)
            XCTAssertThrowsError(try encoder.write(input, finish: true) { _ in }) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("lz4ContentSize"))
            }
            XCTAssertThrowsError(try encoder.write(Data([1]), finish: true) { _ in })
        }
        let encoder = try LZ4FrameEncoder(threads: 2)
        let data = Data(repeating: 0, count: 3 * LZ4FrameEncoder.blockSize)
        var emissions = 0
        XCTAssertThrowsError(try encoder.write(data, finish: true) { _ in
            emissions += 1
            if emissions == 2 { throw CocoaError(.fileWriteUnknown) }
        })
        XCTAssertEqual(encoder.pendingInputBytes, 0)
        XCTAssertThrowsError(try encoder.write(Data(), finish: true) { _ in })
    }
}
