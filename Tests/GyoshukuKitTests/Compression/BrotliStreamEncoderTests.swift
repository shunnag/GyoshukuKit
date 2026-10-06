import Foundation
import XCTest
@testable import GyoshukuKit

final class BrotliStreamEncoderTests: XCTestCase {
    func testSingleStreamingBrotliWithCLIAndKaitoKit() throws {
        let directory = try TestSupport.directory("brotli-stream-encoder")
        for sample in StreamEncoderTestSupport.samples() {
            let encoder = try BrotliStreamEncoder()
            let encoded = try StreamEncoderTestSupport.encode(sample.data) { try encoder.write($0, finish: $1, emit: $2) }
            let url = directory.appendingPathComponent(sample.name + ".br")
            try encoded.write(to: url)
            try ReferenceTool.run(StreamEncoderTestSupport.brotli, ["-t", url.path], in: directory, log: sample.name + "-test")
            try StreamEncoderTestSupport.assertCLI(StreamEncoderTestSupport.brotli, arguments: ["-dc"], url: url,
                                                  input: sample.data, in: directory, label: sample.name + "-decode")
            try StreamEncoderTestSupport.assertKaito(url, equals: sample.data)
            XCTAssertThrowsError(try encoder.write(Data(), finish: true) { _ in }) {
                XCTAssertEqual($0 as? WriterError, .invalidState)
            }
            if sample.data.count > 1024 * 1024 { try FileManager.default.removeItem(at: url) }
        }
    }

    func testBytewiseWritesAndFinalizeWithInput() throws {
        let input = Data("Brotli は全ての write を同じ stream に圧縮する。".utf8)
        let directory = try TestSupport.directory("brotli-stream-boundaries")
        for bytewise in [false, true] {
            let encoder = try BrotliStreamEncoder()
            var output = Data()
            if bytewise {
                for byte in input { try encoder.write(Data([byte])) { output.append($0) } }
                try encoder.write(Data(), finish: true) { output.append($0) }
            } else {
                try encoder.write(input, finish: true) { output.append($0) }
            }
            let url = directory.appendingPathComponent("bytewise-\(bytewise).br")
            try output.write(to: url)
            try StreamEncoderTestSupport.assertCLI(StreamEncoderTestSupport.brotli, arguments: ["-dc"], url: url,
                                                  input: input, in: directory, label: "decode-\(bytewise)")
            try StreamEncoderTestSupport.assertKaito(url, equals: input)
        }
    }

    func testSinkFailureIsTerminal() throws {
        let encoder = try BrotliStreamEncoder()
        XCTAssertThrowsError(try encoder.write(Data([1]), finish: true) { _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try encoder.write(Data(), finish: true) { _ in }) {
            XCTAssertEqual($0 as? WriterError, .invalidState)
        }
    }
}
