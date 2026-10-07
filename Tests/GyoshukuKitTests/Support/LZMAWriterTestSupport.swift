import Foundation
import XCTest
@testable import GyoshukuKit

enum LZMAWriterTestSupport {
    struct Preset {
        let level: Int
        var extreme = false
        let dictionary: Int
        let property: UInt8
        let dictionaryLabel: String
        var label: String { "\(level)\(extreme ? "-extreme" : "")" }
    }
    // xz の preset 表と LZMA2 の辞書 property 表から期待値を固定する。
    static let presets: [Preset] = [
        .init(level: 0, dictionary: 256 << 10, property: 12, dictionaryLabel: "18"),
        .init(level: 1, dictionary: 1 << 20, property: 16, dictionaryLabel: "20"),
        .init(level: 6, dictionary: 8 << 20, property: 22, dictionaryLabel: "23"),
        .init(level: 9, dictionary: 64 << 20, property: 28, dictionaryLabel: "26"),
        .init(level: 9, extreme: true, dictionary: 64 << 20, property: 28, dictionaryLabel: "26")
    ]
    static func items() -> [ExpectedEntry] {
        [.init(name: "日本語.txt", data: LZMAEncoderCorpus.text(size: 128 << 10)),
         .init(name: "random.bin", data: TestCorpus.random(7777)),
         .init(name: "one", data: Data([0xAF])), .init(name: "empty")]
    }
    static func write(_ url: URL, format: ArchiveFormat, options: WriterOptions, items: [ExpectedEntry]) throws {
        let phaseStart = EncoderTestTiming.start()
        defer {
            if EncoderTestTiming.enabled {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                EncoderTestTiming.end("encode.lzma-writer+io", phaseStart, input: items.reduce(0) { $0 + $1.data.count }, output: size)
            }
        }
        let writer = try ArchiveWriter.create(url: url, format: format, options: options)
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
        try writer.finish()
    }
    @discardableResult
    static func verify(_ url: URL, items: [ExpectedEntry], password: String? = nil, metadata: Bool = true) throws -> String {
        let directory = try TestSupport.work(in: url.deletingLastPathComponent())
        let args = password.map { ["-p\($0)"] } ?? []
        try TestSupport.run(ReferenceTool.sevenZip, ["t", url.path] + args, in: directory, log: "7zz-t")
        let listing = try TestSupport.run(ReferenceTool.sevenZip, ["l", "-slt", url.path] + args, in: directory, log: "7zz-l")
        let extracted = directory.appendingPathComponent("extracted")
        try TestSupport.run(ReferenceTool.sevenZip, ["x", "-y", "-o\(extracted.path)", url.path] + args,
            in: directory, log: "7zz-x")
        for item in items {
            let path = extracted.appendingPathComponent(item.name)
            if item.kind == .directory {
                var directory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path, isDirectory: &directory))
                XCTAssertTrue(directory.boolValue)
            } else if item.kind == .symlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), String(decoding: item.data, as: UTF8.self))
            } else { XCTAssertEqual(try Data(contentsOf: path), item.data, item.name) }
        }
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items, password: password, comparesMetadata: metadata)
        return listing
    }
    static func zipPayload(_ url: URL) throws -> Data {
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        let start = 30 + Int(bytes.u16(26)) + Int(bytes.u16(28))
        return bytes.data.subdata(in: start..<(start + Int(bytes.u32(18))))
    }
    static func assertXZProperty(_ bytes: Data, property: UInt8) throws {
        // 公開 block header の VLI 2個を読み、filter ID・properties size・辞書 property を直接検査する。
        var cursor = 14
        _ = try XZFraming.readVLI(bytes, cursor: &cursor, end: bytes.count)
        _ = try XZFraming.readVLI(bytes, cursor: &cursor, end: bytes.count)
        XCTAssertEqual(bytes[cursor], 0x21)
        XCTAssertEqual(bytes[cursor + 1], 1)
        XCTAssertEqual(bytes[cursor + 2], property)
    }
}
