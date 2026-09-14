import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum LHATestSupport {
    static let lhasa = "/opt/homebrew/bin/lha"
    static let sevenZip = "/opt/homebrew/bin/7zz"

    struct Expected {
        let name: String
        var data = Data()
        var kind: EntryKind = .file
        var mode: UInt16 = 0o644
        var date: Date? = ZipTestSupport.date
    }

    struct Output {
        let bytes: Data
        let status: Int32
        var text: String {
            String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .shiftJIS)
                ?? String(decoding: bytes, as: UTF8.self)
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL, log: String) throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            XCTFail("Required independent decoder missing: \(tool)")
            throw CocoaError(.fileNoSuchFile)
        }
        let logURL = directory.appendingPathComponent(log + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["TZ"] = "UTC"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let result = Output(bytes: try Data(contentsOf: logURL), status: process.terminationStatus)
        ZipTestSupport.report("LHA DECODER \(directory.lastPathComponent)/\(log): exit \(result.status)\n\(result.text.suffix(700))")
        return result
    }

    static func clean(_ output: Output, sevenZip: Bool = false) {
        XCTAssertEqual(output.status, 0, output.text)
        for marker in ["warning", "error", "failed", "corrupt"] {
            XCTAssertFalse(output.text.lowercased().contains(marker), output.text)
        }
        if sevenZip { XCTAssertTrue(output.text.contains("Everything is Ok"), output.text) }
    }

    static func verify(_ archive: URL, expected: [Expected], externalNames: [String]? = nil) throws {
        let directory = archive.deletingLastPathComponent()
        let selected = externalNames ?? []
        let externalItems = expected.filter { externalNames == nil || selected.contains($0.name) }
        let listing = try run(lhasa, ["l", archive.path] + selected, in: directory, log: "lha-l")
        clean(listing)
        let verbose = try run(lhasa, ["vv", archive.path] + selected, in: directory, log: "lha-vv")
        clean(verbose)
        let test = try run(lhasa, ["t", archive.path] + selected, in: directory, log: "lha-t")
        clean(test)
        // Lhasa の成功表示は "Tested"。終了値 0 でも全 member を読み飛ばすことがあるため、各行を照合する。
        let tested = test.text.components(separatedBy: "\r").filter { $0.contains("- Tested") }
        XCTAssertEqual(tested.count, externalItems.filter { $0.kind == .file }.count, test.text)
        let sevenTest = try run(sevenZip, ["t", archive.path] + selected, in: directory, log: "7zz-t")
        clean(sevenTest, sevenZip: true)
        let sevenList = try run(sevenZip, ["l", "-slt", archive.path] + selected, in: directory, log: "7zz-l-slt")
        clean(sevenList)
        let listed = SevenZipTestSupport.listingEntries(sevenList.text)
        XCTAssertEqual(listed.map { $0["Path"] ?? "" }, externalItems.map {
            $0.kind == .directory ? String($0.name.dropLast()) : $0.name
        })
        XCTAssertEqual(listed.map { UInt64($0["Size"] ?? "") }, externalItems.map { UInt64($0.data.count) })
        let lhaExtracted = directory.appendingPathComponent("lha-extracted")
        let sevenExtracted = directory.appendingPathComponent("7zz-extracted")
        try FileManager.default.createDirectory(at: lhaExtracted, withIntermediateDirectories: true)
        clean(try run(lhasa, ["xw=" + lhaExtracted.path, archive.path] + selected, in: directory, log: "lha-x"))
        clean(try run(sevenZip, ["x", "-y", "-o" + sevenExtracted.path, archive.path] + selected, in: directory, log: "7zz-x"), sevenZip: true)
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), expected.map(\.name))
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for (index, item) in expected.enumerated() {
            let entry = reader.entries[index]
            XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), item.name)
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(entry.posixPermissions, item.mode, item.name)
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
            XCTAssertFalse(entry.isIncomplete)
            if let date = item.date { XCTAssertEqual(entry.modificationDate, date, item.name) }
            guard let externalIndex = externalItems.firstIndex(where: { $0.name == item.name }) else { continue }
            XCTAssertTrue(listing.text.contains(item.name), listing.text)
            if item.kind == .file {
                XCTAssertTrue(tested.contains { $0.contains(item.name + "\t- Tested") }, test.text)
            } else {
                XCTAssertTrue(listing.text.split(separator: "\n").contains { $0.hasPrefix("d") && $0.hasSuffix(item.name) }, listing.text)
                XCTAssertEqual(listed[externalIndex]["Folder"], "+", sevenList.text)
            }
            if let date = item.date {
                let stamp = dateFormat.string(from: date)
                let lines = verbose.text.components(separatedBy: "\n")
                let line = try XCTUnwrap(lines.firstIndex(of: item.name))
                XCTAssertTrue(lines[line + 1].contains(stamp), verbose.text)
                XCTAssertEqual(listed[externalIndex]["Modified"], stamp, sevenList.text)
            }
            for extracted in [lhaExtracted, sevenExtracted] {
                let file = extracted.appendingPathComponent(item.name)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                if item.kind == .file {
                    XCTAssertEqual(try Data(contentsOf: file), item.data, item.name)
                    if let date = item.date { XCTAssertEqual(attributes[.modificationDate] as? Date, date, item.name) }
                } else {
                    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
                }
                if extracted == lhaExtracted {
                    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, item.mode, item.name)
                }
            }
        }
    }

    static func random(_ count: Int, alphabetMask: UInt8 = 255) -> Data {
        // 決定的な擬似乱数を使い、実行ごとの偶然の圧縮率で stored 判定が変わらないようにする。
        var state: UInt64 = 0xD137_923A_6E25_9B41
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            bytes.append(UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56) & alphabetMask)
        }
        return Data(bytes)
    }

    // bitwise の独立実装で CRC table の実装ミスも検出する。
    static func crc(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
}

struct LHABytes {
    struct Member {
        let offset: Int
        let header: Data
        let payload: Data
        let extensions: [UInt8: Data]
        let crcOffset: Int
        var method: String { String(decoding: header[2..<7], as: UTF8.self) }
        var size: UInt32 { LHATestSupport.uint32(header, 11) }
    }

    let members: [Member]

    init(_ data: Data) throws {
        var members: [Member] = []
        var offset = 0
        while offset < data.count, data[offset] != 0 {
            guard data.count - offset >= 26 else { throw CocoaError(.fileReadCorruptFile) }
            let size = Int(LHATestSupport.uint16(data, offset))
            guard size >= 26, size <= data.count - offset else { throw CocoaError(.fileReadCorruptFile) }
            let header = data.subdata(in: offset..<(offset + size))
            XCTAssertEqual(header[19], 0x20)
            XCTAssertEqual(header[20], 2)
            XCTAssertEqual(header[23], 0x55)
            var cursor = 24
            var fields: [UInt8: Data] = [:]
            var crcOffset: Int?
            while true {
                guard cursor + 2 <= size else { throw CocoaError(.fileReadCorruptFile) }
                let length = Int(LHATestSupport.uint16(header, cursor))
                if length == 0 { cursor += 2; break }
                guard length >= 3, length <= size - cursor else { throw CocoaError(.fileReadCorruptFile) }
                let type = header[cursor + 2]
                XCTAssertNil(fields[type])
                fields[type] = header.subdata(in: (cursor + 3)..<(cursor + length))
                if type == 0 { crcOffset = cursor + 3 }
                cursor += length
            }
            XCTAssertTrue(header[cursor...].allSatisfy { $0 == 0 })
            let crc = try XCTUnwrap(crcOffset)
            var authenticated = header
            authenticated[crc] = 0
            authenticated[crc + 1] = 0
            XCTAssertEqual(LHATestSupport.uint16(header, crc), LHATestSupport.crc(authenticated))
            let packedSize = Int(LHATestSupport.uint32(header, 7))
            guard packedSize <= data.count - offset - size else { throw CocoaError(.fileReadCorruptFile) }
            let payload = data.subdata(in: (offset + size)..<(offset + size + packedSize))
            members.append(Member(offset: offset, header: header, payload: payload, extensions: fields, crcOffset: crc))
            offset += size + packedSize
        }
        XCTAssertEqual(Data(data[offset...]), Data([0]))
        self.members = members
    }
}
