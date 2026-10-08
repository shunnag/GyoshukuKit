import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

/// 実ツール不在は ReferenceTool の方針どおり失敗にする。復号は公開 KaitoKit reader 経由。
enum StreamEncoderTestSupport {
    static let lz4 = "/opt/homebrew/bin/lz4"
    static let brotli = "/opt/homebrew/bin/brotli"
    static let compress = "/usr/bin/compress"

    static func samples() -> [(name: String, data: Data)] {
        [("empty", Data()), ("one", Data([0xA7])), ("zeros-64k", Data(repeating: 0, count: 65_536)),
         ("random-9m", TestCorpus.random(9 * 1024 * 1024)), ("text-12m", TestCorpus.pseudoSource(mebibytes: 12))]
    }

    /// 非ゼロ startIndex の Data slice、4 MiB をまたぐ入力、空 write、別呼出しの finish を使う。
    static func encode(_ input: Data, write: (Data, Bool, (Data) throws -> Void) throws -> Void) throws -> Data {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("encode.stream+append", phaseStart, input: input.count) }
        var encoded = Data()
        var appendTime: UInt64 = 0
        let emit: (Data) -> Void = { data in
            let start = EncoderTestTiming.start()
            encoded.append(data)
            if EncoderTestTiming.enabled { appendTime += DispatchTime.now().uptimeNanoseconds - start }
        }
        defer { EncoderTestTiming.duration("test.output-append", appendTime, input: input.count, output: encoded.count) }
        try write(Data(), false, emit)
        let sizes = [1, 7, 65_537, IOChunk.size - 1, IOChunk.size + 3, 5 * 1024 * 1024 + 11]
        var offset = input.startIndex, index = 0
        while offset < input.endIndex {
            let end = min(input.endIndex, offset + sizes[index % sizes.count])
            try write(input[offset..<end], false, emit)
            try write(Data(), false, emit)
            offset = end
            index += 1
        }
        try write(Data(), true, emit)
        return encoded
    }

    static func assertKaito(_ url: URL, equals input: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("decode.kaito+compare", phaseStart, input: input.count) }
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.count, 1, file: file, line: line)
        let entry = try XCTUnwrap(reader.entries.first, file: file, line: line)
        let stream = try reader.stream(entry)
        var buffer = [UInt8](repeating: 0, count: 65_537)
        var offset = input.startIndex
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            guard count <= input.endIndex - offset else {
                XCTFail("KaitoKit produced too many bytes: \(url.lastPathComponent)", file: file, line: line)
                return
            }
            XCTAssertEqual(Data(buffer.prefix(count)), input[offset..<(offset + count)],
                           "\(url.lastPathComponent) at \(offset)", file: file, line: line)
            offset += count
        }
        XCTAssertEqual(offset, input.endIndex, url.lastPathComponent, file: file, line: line)
    }

    static func assertCLI(_ tool: String, arguments: [String], url: URL, input: Data,
                          in directory: URL, label: String) throws {
        let output = try ReferenceTool.run(tool, arguments + [url.path], in: directory,
                                          log: label, standardOutput: label + ".decoded")
        XCTAssertEqual(output.bytes, input, label)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".decoded"))
    }

    static func assertCompressCLI(_ url: URL, input: Data, in directory: URL, label: String) throws {
        let tool = ReferenceTool.gzip
        try assertCLI(ReferenceTool.sevenZip, arguments: ["x", "-so"], url: url, input: input,
                      in: directory, label: label + "-7zz")
        if !input.isEmpty {
            try assertCLI(tool, arguments: ["-dc"], url: url, input: input, in: directory, label: label)
            try assertUncompressCLI(url, input: input, in: directory, label: label + "-uncompress")
            return
        }
        // .Z には EOF code が無く、空は header のみ。BSD gzip はこれを unexpected EOF として拒否する。
        // その実ツールの制限を明示して確認し、KaitoKit では空を正常に復元する。
        let output = try ReferenceTool.run(tool, ["-dc", url.path], in: directory, log: label,
                                          expect: .oneOf([0, 1]), standardOutput: label + ".decoded")
        XCTAssertTrue(output.bytes.isEmpty)
        if output.status != 0 {
            let log = try String(contentsOf: directory.appendingPathComponent(label + ".log"), encoding: .utf8)
            XCTAssertTrue(log.contains("unexpected end of file"), log)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".decoded"))
        try assertUncompressCLI(url, input: input, in: directory, label: label + "-uncompress")
    }

    private static func assertUncompressCLI(_ url: URL, input: Data, in directory: URL, label: String) throws {
        let tool = "/usr/bin/uncompress"
        let output = try ReferenceTool.run(tool, ["-c", url.path], in: directory, log: label,
                                          expect: .unchecked, standardOutput: label + ".decoded")
        if output.status == 0 {
            XCTAssertEqual(output.bytes, input, label)
        } else {
            let log = try String(contentsOf: directory.appendingPathComponent(label + ".log"), encoding: .utf8)
            if input.isEmpty {
                // BSD compress(1) BUGS に記載の空 stream の制限。空以外には適用しない。
                XCTAssertEqual(output.status, 1)
                XCTAssertTrue(log.contains("Undefined error: 0"), log)
                XCTAssertTrue(output.bytes.isEmpty)
                try FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".decoded"))
                return
            }
            // -c の stdout 再 open だけが禁止される環境では、同じ OS decoder の file 出力を照合する。
            guard output.status == 1 && log.contains("/dev/stdout: Operation not permitted") else {
                XCTFail("uncompress -c failed: \(log)")
                throw CocoaError(.fileReadUnknown)
            }
            let plain = directory.appendingPathComponent(label + ".file-output")
            let copy = URL(fileURLWithPath: plain.path + ".Z")
            try FileManager.default.copyItem(at: url, to: copy)
            defer {
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.removeItem(at: plain)
            }
            try ReferenceTool.run(tool, ["-f", copy.path], in: directory, log: label + "-file")
            XCTAssertEqual(try Data(contentsOf: plain), input, label)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".decoded"))
    }

    static func compressReference(_ plain: URL, maxbits: Int, in directory: URL, label: String) throws -> Data {
        let output = try ReferenceTool.run(compress, ["-c", "-b", "\(maxbits)", plain.path],
                                          in: directory, log: label + "-compress", expect: .unchecked,
                                          standardOutput: label + ".reference.Z")
        if output.status == 0 || output.status == 2 { return output.bytes }
        let log = try String(contentsOf: directory.appendingPathComponent(label + "-compress.log"), encoding: .utf8)
        // -c の stdout 再 open だけが禁止される環境では、同じ OS codec の file 出力で比較する。
        guard output.status == 1 && log.contains("/dev/stdout: Operation not permitted") else {
            XCTFail("compress -c failed: \(log)")
            throw CocoaError(.fileReadUnknown)
        }
        let copy = directory.appendingPathComponent(label + ".reference.raw")
        try FileManager.default.copyItem(at: plain, to: copy)
        let encoded = URL(fileURLWithPath: copy.path + ".Z")
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: encoded)
        }
        try ReferenceTool.run(compress, ["-f", "-b", "\(maxbits)", copy.path], in: directory, log: label + "-compress-file")
        return try Data(contentsOf: encoded)
    }
}
