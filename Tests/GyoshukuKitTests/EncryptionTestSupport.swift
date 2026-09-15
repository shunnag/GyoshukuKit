import Foundation
import Compression
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum EncryptionTestSupport {
    static let password = "Gyoshuku-test-2026"

    struct Item {
        let name: String
        var data = Data()
        var kind: EntryKind = .file
    }

    static var corpus: [Item] {
        [0, 5, 19, 20, 21].map { Item(name: "size-\($0).txt", data: Data(repeating: 0x41, count: $0)) }
        + [Item(name: "deflated.txt", data: Data(repeating: 0x51, count: 1024 * 1024)),
           Item(name: "stored.jpg", data: Data((0..<(1024 * 1024 + 31)).map { UInt8(truncatingIfNeeded: $0) })),
           Item(name: "directory/", kind: .directory),
           Item(name: "link", data: Data("size-5.txt".utf8), kind: .symlink)]
    }

    static func writeCorpus(_ writer: ArchiveWriter, in directory: URL) throws {
        for item in corpus {
            switch item.kind {
            case .directory: try writer.addDirectory(item.name)
            case .symlink:
                let link = directory.appendingPathComponent("source-link")
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "size-5.txt")
                try writer.add(contentsOf: link, as: item.name)
            default: try writer.add(data: item.data, as: item.name, modificationDate: ZipTestSupport.date)
            }
        }
    }

    @discardableResult
    static func verify(_ url: URL, items: [Item], password: String? = EncryptionTestSupport.password,
                       encrypted: (Item) -> Bool) throws -> ArchiveReader {
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), items.map(\.name))
        for (entry, item) in zip(reader.entries, items) {
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(entry.isEncrypted, encrypted(item), item.name)
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
        }
        return reader
    }

    // 失敗 oracle も実行し、password prompt は EOF で終了させる。失敗を skip しない。
    @discardableResult
    static func run(_ arguments: [String], archive: URL, log: String, success: Bool = true,
                    tool: String = SevenZipTestSupport.tool) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            XCTFail("Required reference tool missing: \(tool)")
            throw CocoaError(.fileNoSuchFile)
        }
        let logURL = archive.deletingLastPathComponent().appendingPathComponent(log + ".log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        if success {
            XCTAssertEqual(process.terminationStatus, 0, text)
            for marker in ["headers error", "warning", "errors:"] {
                XCTAssertFalse(text.lowercased().contains(marker), text)
            }
        } else {
            XCTAssertNotEqual(process.terminationStatus, 0, text)
        }
        ZipTestSupport.report("ENCRYPTION REFERENCE \(log): exit \(process.terminationStatus)")
        return text
    }

    static func spoolFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".gyoshuku-zipcrypto-") }
    }

    static func localRecords(_ url: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url)
        let data = try Data(contentsOf: url)
        return try Dictionary(uniqueKeysWithValues: reader.entries.map { entry in
            let raw = try XCTUnwrap(reader.rawRecord(of: entry))
            return (entry.name, data.subdata(in: Int(raw.recordRange.lowerBound)..<Int(raw.recordRange.upperBound)))
        })
    }

    static func fixture(in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent("original.txt")
        try Data("original encrypted content\n".utf8).write(to: input)
        let archive = directory.appendingPathComponent("source.zip")
        try run(["a", "-tzip", "-mem=AES256", "-p" + password, archive.path, input.path],
                archive: archive, log: "7zz-fixture")
        return archive
    }

    // 固定 seed の擬似ソースコード。512 KiB ごとの独立した内容を一度繰り返し、
    // 256 KiB reset では失われる距離の一致を含める。16 MiB 境界は module の間に置く。
    static func pseudoText(mebibytes: Int) -> Data {
        var state: UInt64 = 0x4D59_5DF4_D0F3_3173
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        let halfSize = 512 * 1024
        var result = Data()
        result.reserveCapacity(mebibytes * 1024 * 1024)
        for _ in 0..<mebibytes {
            var block = Data()
            block.reserveCapacity(halfSize)
            while block.count < halfSize {
                let line = Data("let item_\(String(next(), radix: 16)) = lookup(0x\(String(next(), radix: 16)));\n".utf8)
                block.append(line.prefix(halfSize - block.count))
            }
            result.append(block)
            result.append(block)
        }
        return result
    }

    // 製品の compressor / chunk size を参照せず、Apple の buffer API を一度だけ呼ぶ oracle。
    // XZ framing だけを除き、7z の packed size と比較する（暗号化時の最大 15 byte pad は含める）。
    static func wholeBufferLZMA2(_ input: Data) throws -> XZLZMA2 {
        let capacity = input.count + max(65_536, input.count / 16)
        var output = Data(count: capacity)
        let count: Int = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(capacity),
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(input.count),
                    nil, COMPRESSION_LZMA)
            }
        }
        guard count > 0 else {
            XCTFail("Reference compression_encode_buffer failed")
            throw CocoaError(.fileWriteUnknown)
        }
        output.removeSubrange(count..<output.count)
        let result = try XZLZMA2.extract(output)
        XCTAssertEqual(result.uncompressedSize, UInt64(input.count))
        return result
    }
}

// 公開 7z byte 表から folder の coder / bind / size だけを検査する。製品 parser は使わない。
struct EncryptedSevenZipHeader {
    struct Folder {
        var methods: [[UInt8]] = []
        var properties: [Data] = []
        var binds: [(UInt64, UInt64)] = []
        var unpackSizes: [UInt64] = []
    }
    let encoded: Bool
    let packOffset: UInt64
    let packedSizes: [UInt64]
    let folders: [Folder]

    init(_ archive: Data) throws {
        let bytes = ZipBytes(data: archive)
        let offset = Int(bytes.u64(12)) + 32
        let size = Int(bytes.u64(20))
        let header = archive.subdata(in: offset..<(offset + size))
        XCTAssertEqual(CRC32.checksum(archive.subdata(in: 12..<32)), bytes.u32(8))
        XCTAssertEqual(CRC32.checksum(header), bytes.u32(28))
        var cursor = Cursor(data: header)
        let type = try cursor.byte()
        encoded = type == 0x17
        // Plain header starts 01 04; EncodedHeader starts 17 directly followed by StreamsInfo.
        if !encoded {
            guard type == 1 else { throw CocoaError(.fileReadCorruptFile) }
            try cursor.expect(0x04)
        }
        try cursor.expect(0x06)
        packOffset = try cursor.number()
        let packCount = Int(try cursor.number())
        try cursor.expect(0x09)
        packedSizes = try (0..<packCount).map { _ in try cursor.number() }
        try cursor.expect(0)
        try cursor.expect(0x07)
        try cursor.expect(0x0B)
        let folderCount = Int(try cursor.number())
        try cursor.expect(0)
        var parsed: [Folder] = []
        for _ in 0..<folderCount {
            var folder = Folder()
            let coders = Int(try cursor.number())
            for _ in 0..<coders {
                let flags = try cursor.byte()
                XCTAssertEqual(flags & 0x10, 0)
                folder.methods.append(Array(try cursor.take(Int(flags & 0x0F))))
                let propertySize = flags & 0x20 == 0 ? 0 : Int(try cursor.number())
                folder.properties.append(try cursor.take(propertySize))
            }
            for _ in 0..<(coders - 1) { folder.binds.append((try cursor.number(), try cursor.number())) }
            parsed.append(folder)
        }
        try cursor.expect(0x0C)
        for index in parsed.indices {
            parsed[index].unpackSizes = try parsed[index].methods.map { _ in try cursor.number() }
        }
        folders = parsed
    }

    private struct Cursor {
        let data: Data
        var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw CocoaError(.fileReadCorruptFile) }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 { try take(1)[0] }
        mutating func expect(_ value: UInt8) throws {
            let actual = try byte()
            XCTAssertEqual(actual, value)
            guard actual == value else { throw CocoaError(.fileReadCorruptFile) }
        }
        mutating func number() throws -> UInt64 {
            let first = try byte()
            let count = (0..<8).first { first & (0x80 >> $0) == 0 } ?? 8
            var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(try byte()) << (8 * index) }
            if count < 8 { value |= UInt64(first & (0x7F >> count)) << (8 * count) }
            return value
        }
    }
}
