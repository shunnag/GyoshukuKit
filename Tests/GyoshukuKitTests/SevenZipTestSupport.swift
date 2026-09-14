import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum SevenZipTestSupport {
    static let tool = "/opt/homebrew/bin/7zz"

    struct Expected {
        let name: String
        var data = Data()
        var kind: EntryKind = .file
        var mode: UInt16 = 0o644
        var date: Date? = ZipTestSupport.date
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL, log: String, success: Bool = true) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            XCTFail("Required reference tool missing: \(tool)")
            throw CocoaError(.fileNoSuchFile)
        }
        let logURL = directory.appendingPathComponent(log + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["TZ"] = "UTC"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        if success {
            XCTAssertEqual(process.terminationStatus, 0, text)
            for marker in ["warning", "headers error", "errors:"] { XCTAssertFalse(text.lowercased().contains(marker), text) }
            if arguments.first == "t" || arguments.first == "x" { XCTAssertTrue(text.contains("Everything is Ok"), text) }
        } else {
            XCTAssertNotEqual(process.terminationStatus, 0, text)
            XCTAssertFalse(text.contains("Everything is Ok"), text)
        }
        ZipTestSupport.report("7Z REFERENCE \(directory.lastPathComponent)/\(log): exit \(process.terminationStatus)\n\(text)")
        return text
    }

    static func listingEntries(_ text: String) -> [[String: String]] {
        let body = text.components(separatedBy: "----------\n").last ?? ""
        return body.components(separatedBy: "\n\n").compactMap { block in
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " = ")
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            return fields["Path"] == nil ? nil : fields
        }
    }

    static func verify(_ archive: URL, expected: [Expected]) throws {
        let directory = archive.deletingLastPathComponent()
        try run(["t", archive.path], in: directory, log: "7zz-t")
        let listing = try run(["l", "-slt", archive.path], in: directory, log: "7zz-l-slt")
        let listed = listingEntries(listing)
        XCTAssertEqual(listed.map { Data(($0["Path"] ?? "").utf8) }, expected.map { Data($0.name.utf8) })
        XCTAssertEqual(listed.map { UInt64($0["Size"] ?? "") }, expected.map { UInt64($0.data.count) })
        XCTAssertTrue(listing.contains("Solid = -"), listing)
        let extracted = directory.appendingPathComponent("extracted")
        try run(["x", "-y", archive.path, "-o" + extracted.path], in: directory, log: "7zz-x")
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map { Data($0.name.utf8) }, expected.map { Data($0.name.utf8) })
        XCTAssertEqual(reader.entries.count, expected.count)
        for (entry, item) in zip(reader.entries, expected) {
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), item.name)
            XCTAssertEqual(entry.posixPermissions, item.mode, item.name)
            if let date = item.date { XCTAssertEqual(entry.modificationDate, date, item.name) }
            XCTAssertFalse(entry.isEncrypted)
            XCTAssertEqual(entry.solidGroup, -1)
            if !item.data.isEmpty { XCTAssertEqual(entry.crc32, CRC32.checksum(item.data), item.name) }
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
            let restored = extracted.appendingPathComponent(item.name)
            switch item.kind {
            case .file:
                XCTAssertEqual(try Data(contentsOf: restored), item.data, item.name)
            case .directory:
                var isDirectory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path, isDirectory: &isDirectory))
                XCTAssertTrue(isDirectory.boolValue)
            case .symlink:
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: restored.path),
                               String(decoding: item.data, as: UTF8.self))
            default: XCTFail("Unexpected fixture kind")
            }
        }
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }

    static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    static func patchCRC(_ data: inout Data, at offset: Int, over range: Range<Int>) {
        let crc = CRC32.checksum(data.subdata(in: range))
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
    }
}

// 作成する非 solid subset を独立に読む。CRC の位置や EmptyFile の添字を byte 列の検索だけで判定しない。
struct SevenZipBytes {
    let header: Data
    var packedSizes: [UInt64] = []
    var unpackedSizes: [UInt64] = []
    var properties: [UInt8] = []
    var crcs: [UInt32] = []
    var fileCount = 0
    var fileProperties: [UInt8: Data] = [:]

    init(_ data: Data) throws {
        XCTAssertEqual(Array(data.prefix(8)), [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
        XCTAssertEqual(SevenZipTestSupport.uint32(data, 8), CRC32.checksum(data.subdata(in: 12..<32)))
        let offset = 32 + Int(SevenZipTestSupport.uint64(data, 12))
        let size = Int(SevenZipTestSupport.uint64(data, 20))
        header = data.subdata(in: offset..<(offset + size))
        XCTAssertEqual(offset + size, data.count)
        XCTAssertEqual(SevenZipTestSupport.uint32(data, 28), CRC32.checksum(header))
        var cursor = Cursor(data: header)
        try cursor.expect(1)
        if cursor.peek == 4 {
            try cursor.expect(4)
            try cursor.expect(6)
            XCTAssertEqual(try cursor.number(), 0)
            let count = Int(try cursor.number())
            try cursor.expect(9)
            for _ in 0..<count { packedSizes.append(try cursor.number()) }
            try cursor.expect(0)
            try cursor.expect(7)
            try cursor.expect(11)
            XCTAssertEqual(try cursor.number(), UInt64(count))
            try cursor.expect(0)
            for _ in 0..<count {
                for byte: UInt8 in [1, 0x21, 0x21, 1] { try cursor.expect(byte) }
                properties.append(try cursor.byte())
            }
            try cursor.expect(12)
            for _ in 0..<count { unpackedSizes.append(try cursor.number()) }
            // UnpackInfo に CRC が無いことも確認し、SubStreamsInfo の CRC が実際に使われる構成にする。
            for byte: UInt8 in [0, 8, 10, 1] { try cursor.expect(byte) }
            for _ in 0..<count { crcs.append(SevenZipTestSupport.uint32(try cursor.take(4), 0)) }
            try cursor.expect(0)
            try cursor.expect(0)
        }
        if cursor.peek == 5 {
            try cursor.expect(5)
            fileCount = Int(try cursor.number())
            while cursor.peek != 0 {
                let id = try cursor.byte()
                let size = Int(try cursor.number())
                fileProperties[id] = try cursor.take(size)
            }
            try cursor.expect(0)
        }
        try cursor.expect(0)
        XCTAssertEqual(cursor.offset, header.count)
    }

    private struct Cursor {
        let data: Data
        var offset = 0
        var peek: UInt8? { offset < data.count ? data[offset] : nil }
        mutating func byte() throws -> UInt8 { try take(1)[0] }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw CocoaError(.fileReadCorruptFile) }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func expect(_ expected: UInt8) throws {
            let actual = try byte()
            XCTAssertEqual(actual, expected)
            guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
        }
        mutating func number() throws -> UInt64 {
            let first = try byte()
            let count = (0..<8).first { first & (0x80 >> $0) == 0 } ?? 8
            let low = try take(count)
            var result: UInt64 = 0
            for (index, byte) in low.enumerated() { result |= UInt64(byte) << (8 * index) }
            if count < 8 { result |= UInt64(first & (0x7F >> count)) << (8 * count) }
            return result
        }
    }
}
