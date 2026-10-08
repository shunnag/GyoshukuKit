import Foundation
import XCTest
@testable import GyoshukuKit

enum SingleStreamTestSupport {
    static let newTarFormats: [GyoshukuKit.ArchiveFormat] = [.tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress]

    static func format(_ tar: GyoshukuKit.ArchiveFormat) throws -> SingleStreamFormat {
        try XCTUnwrap(SingleStreamFormat.allCases.first { $0.archiveFormat == tar })
    }

    static func suffix(_ format: SingleStreamFormat) -> String {
        switch format {
        case .gzip: "gz"
        case .bzip2: "bz2"
        case .xz: "xz"
        case .zstd: "zst"
        case .lzma: "lzma"
        case .lzip: "lz"
        case .lz4: "lz4"
        case .brotli: "br"
        case .compress: "Z"
        }
    }

    static func decoder(_ format: SingleStreamFormat) -> (String, [String]) {
        switch format {
        case .gzip: (ReferenceTool.gzip, ["-dc"])
        case .bzip2: (ReferenceTool.bzip2, ["-dc"])
        case .xz: (ReferenceTool.xz, ["-dc"])
        case .zstd: (ReferenceTool.zstd, ["-dc"])
        case .lzma: (ReferenceTool.xz, ["--format=lzma", "-dc"])
        case .lzip: (ReferenceTool.lzip, ["-dc"])
        case .lz4: (StreamEncoderTestSupport.lz4, ["-dc"])
        case .brotli: (StreamEncoderTestSupport.brotli, ["-dc"])
        case .compress: ("/usr/bin/uncompress", ["-c"])
        }
    }

    static func check(_ url: URL, format: SingleStreamFormat, in directory: URL, label: String) throws {
        if [.zstd, .lzip, .lz4, .brotli].contains(format) {
            try ReferenceTool.run(decoder(format).0, ["-t", url.path], in: directory, log: label + "-test")
        }
    }

    static func assertCLI(_ url: URL, format: SingleStreamFormat, input: Data, in directory: URL, label: String) throws {
        try check(url, format: format, in: directory, label: label)
        if format == .compress {
            // BSD の空 .Z と制限付き stdout の扱いも既存 codec の実ツール試験と共有する。
            try StreamEncoderTestSupport.assertCompressCLI(url, input: input, in: directory, label: label)
        } else {
            let (tool, arguments) = decoder(format)
            try StreamEncoderTestSupport.assertCLI(tool, arguments: arguments, url: url, input: input,
                                                  in: directory, label: label)
        }
    }

    /// decoder と bsdtar を実際の pipe で結ぶ。両 process の終了値を検査する。
    static func tarTool(_ url: URL, format: SingleStreamFormat, arguments: [String], in directory: URL,
                        label: String) throws -> String {
        let (tool, decodeArguments) = decoder(format)
        _ = try ReferenceTool.require([tool])
        let pipe = Pipe()
        let errorURL = directory.appendingPathComponent(label + "-decoder.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: tool)
        decoder.arguments = decodeArguments + [url.path]
        decoder.environment = ProcessInfo.processInfo.environment.merging(ReferenceTool.englishUTF8) { $1 }
        decoder.standardOutput = pipe
        decoder.standardError = errors
        try decoder.run()
        try pipe.fileHandleForWriting.close()
        let tar = try ReferenceTool.run(ReferenceTool.bsdtar, arguments, in: directory, log: label,
                                       expect: .unchecked, stdin: pipe.fileHandleForReading,
                                       environment: ["LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"])
        try pipe.fileHandleForReading.close()
        decoder.waitUntilExit()
        let diagnostic = try String(contentsOf: errorURL, encoding: .utf8)
        if format == .compress, decoder.terminationStatus == 1,
           diagnostic.contains("/dev/stdout: Operation not permitted") {
            // -c だけが制限された場合も、同じ OS decoder の file 出力を bsdtar の stdin へ渡す。
            let decoded = directory.appendingPathComponent(label + ".tar")
            let copy = URL(fileURLWithPath: decoded.path + ".Z")
            try FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: copy); try? FileManager.default.removeItem(at: decoded) }
            try ReferenceTool.run(tool, ["-f", copy.path], in: directory, log: label + "-decode-file")
            let input = try FileHandle(forReadingFrom: decoded)
            defer { try? input.close() }
            return try ReferenceTool.run(ReferenceTool.bsdtar, arguments, in: directory, log: label + "-file",
                stdin: input, environment: ["LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"]).utf8Text
        }
        XCTAssertEqual(decoder.terminationStatus, 0, diagnostic)
        XCTAssertEqual(tar.status, 0, tar.utf8Text)
        return tar.utf8Text
    }

    /// trailer の member size で後ろから辿る独立検査器。製品の framing を使わない。
    static func lzipMemberRanges(_ bytes: Data) throws -> [Range<Int>] {
        var end = bytes.count
        var members: [Range<Int>] = []
        while end > 0 {
            guard end >= 36 else { throw CocoaError(.fileReadCorruptFile) }
            var size: UInt64 = 0
            for index in 0..<8 { size |= UInt64(bytes[end - 8 + index]) << (8 * index) }
            guard size >= 36, size <= UInt64(end) else { throw CocoaError(.fileReadCorruptFile) }
            let start = end - Int(size)
            XCTAssertEqual(bytes[start..<(start + 5)], Data([0x4C, 0x5A, 0x49, 0x50, 1]))
            members.append(start..<end)
            end = start
        }
        return members.reversed()
    }
}
