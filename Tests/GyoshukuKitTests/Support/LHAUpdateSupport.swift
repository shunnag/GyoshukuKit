import Foundation
import CryptoKit
import XCTest
import KaitoKit
@testable import GyoshukuKit

enum LHAUpdateSupport {
    static let accepted = ["tl-S3b", "tl-S2", "tl-S1", "tl-S6", "tl-S7", "tl-S5b", "lh4-small", "lh6-small", "lh7-small",
                           "names-cp932-mixed", "names-ascii", "level1-times", "level0-unix", "maclha-nm-level1"]
    static let fixtureRoot = TestPaths.fixtures.appendingPathComponent("lha-updater")
    struct Fixture: Decodable { let name: String, file: String, storage: String, logicalSize: UInt64, size: Int, sha256: String }
    static func fixture(_ name: String, in root: URL) throws -> URL {
        struct Manifest: Decodable { let fixtures: [Fixture] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json")))
        let item = try XCTUnwrap(manifest.fixtures.first { $0.name == name })
        let data = try XCTUnwrap(Data(base64Encoded: Data(contentsOf: fixtureRoot.appendingPathComponent(item.file)), options: .ignoreUnknownCharacters))
        XCTAssertEqual(data.count, item.size)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), item.sha256)
        let url = root.appendingPathComponent(name + ".lzh")
        try data.write(to: url)
        if item.storage == "sparse-prefix" {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.truncate(atOffset: item.logicalSize)
        }
        return url
    }
    static func scan(_ url: URL) throws -> (LHALayout, ZipUpdateSource, ArchiveReader) {
        let source = try ZipUpdateSource(url: url)
        let reader = try ArchiveReader.open(source: source, sourceURL: url, options: .init(
            limits: .init(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        return (try LHALayout.scan(source: source, reader: reader), source, reader)
    }
    static func generated(_ root: URL, count: Int = 6, size: Int = 513) throws -> URL {
        let url = root.appendingPathComponent("source.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha, options: .init(compressionThreads: 2))
        for index in 0..<count {
            try writer.add(data: LHATestSupport.random(size, alphabetMask: 0xFF), as: String(format: "file-%06d", index), modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        return url
    }
    static func bytes(_ source: ZipUpdateSource, _ range: Range<UInt64>) throws -> Data {
        try source.bytes(at: range.lowerBound, count: Int(range.upperBound - range.lowerBound))
    }
    static func digest(_ reader: ArchiveReader, _ index: Int) throws -> Data {
        Data(SHA256.hash(data: try reader.read(reader.entries[index])))
    }
    static func unchanged(_ before: (LHALayout, ZipUpdateSource, ArchiveReader), _ after: (LHALayout, ZipUpdateSource, ArchiveReader), indices: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
        for index in indices {
            let name = before.2.entries[index].name
            let new = try XCTUnwrap(after.2.entries.firstIndex { $0.name == name }, name, file: file, line: line)
            let a = try before.0.member(index), b = try after.0.member(new)
            XCTAssertEqual(try bytes(before.1, a.headerRange.lowerBound..<a.dataRange.upperBound), try bytes(after.1, b.headerRange.lowerBound..<b.dataRange.upperBound), name, file: file, line: line)
            XCTAssertEqual(try digest(before.2, index), try digest(after.2, new), name, file: file, line: line)
        }
    }
}

/// Independent test builder; length/checksum fields are assembled without the production writer.
enum LHAHeaderBuilder {
    static func le(_ value: UInt64, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func header(level: UInt8, name: Data, packed: UInt64, original: UInt64, crc: UInt16,
                       method: String = "-lh0-", os: UInt8 = 0x55, attribute: UInt8 = 0x20,
                       extensions: [(UInt8, Data)] = [], unix: Data = Data()) -> Data {
        let fields = Data(method.utf8) + le(packed, 4) + le(original, 4) + le(level < 2 ? 0x576EB1AA : 1_700_000_001, 4) + Data([attribute, level])
        if level == 0 {
            var h = Data([0, 0]) + fields + Data([UInt8(name.count)]) + name + le(UInt64(crc), 2) + (unix.isEmpty ? Data() : Data([os]) + unix)
            h[0] = UInt8(h.count - 2); h[1] = h.dropFirst(2).reduce(0, &+)
            return h
        }
        if level == 1 {
            let sizes = extensions.map { $0.1.count + 3 }
            let total = sizes.reduce(0, +)
            var h = Data([0, 0]) + fields + Data([UInt8(name.count)]) + name + le(UInt64(crc), 2) + Data([os]) + le(UInt64(sizes.first ?? 0), 2)
            h.replaceSubrange(7..<11, with: le(packed + UInt64(total), 4))
            h[0] = UInt8(h.count - 2); h[1] = h.dropFirst(2).reduce(0, &+)
            var crcOffset: Int?
            for (index, item) in extensions.enumerated() {
                if item.0 == 0 { crcOffset = h.count + 1 }
                h += Data([item.0]) + item.1 + le(UInt64(index + 1 < sizes.count ? sizes[index + 1] : 0), 2)
            }
            if let at = crcOffset { h.replaceSubrange(at..<(at + 2), with: le(UInt64(LHATestSupport.crc(h)), 2)) }
            return h
        }
        let width = level == 3 ? 4 : 2
        var h = (level == 3 ? le(4, 2) : Data([0, 0])) + fields + le(UInt64(crc), 2) + Data([os])
        if level == 3 { h += Data(count: 4) }
        var common = Data(count: 2)
        let exts = [(UInt8(1), name)] + extensions
        let total = h.count + width + 1 + 2 + exts.reduce(0) { $0 + width + 1 + $1.1.count } + width
        if level == 2 && total & 255 == 0 { common.append(0) }
        let crcOffset = h.count + width + 1
        for (type, data) in [(UInt8(0), common)] + exts { h += le(UInt64(width + 1 + data.count), width) + Data([type]) + data }
        h += Data(count: width)
        h.replaceSubrange(level == 3 ? 24..<28 : 0..<2, with: le(UInt64(h.count), level == 3 ? 4 : 2))
        h.replaceSubrange(crcOffset..<(crcOffset + 2), with: le(UInt64(LHATestSupport.crc(h)), 2))
        return h
    }
    static func member(level: UInt8, name: String, data: Data = Data(), directory: Bool = false) -> Data {
        let raw = name.data(using: .shiftJIS)!
        return header(level: level, name: raw, packed: UInt64(data.count), original: UInt64(data.count),
                      crc: LHATestSupport.crc(data), method: directory ? "-lhd-" : "-lh0-") + data
    }
}
