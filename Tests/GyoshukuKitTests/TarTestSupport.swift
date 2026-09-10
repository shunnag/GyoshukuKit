import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum TarTestSupport {
    struct Expected {
        var name: String
        var data = Data()
        var kind: EntryKind = .file
        var permissions: UInt16 = 0o644
        var date: Date? = ZipTestSupport.date
        var link: String? = nil
    }

    static func verify(_ archive: URL, expected: [Expected], gzip: Bool = false) throws {
        let directory = archive.deletingLastPathComponent()
        let listing = try ZipTestSupport.run("/usr/bin/bsdtar", ["-tf", archive.path], in: directory, log: "bsdtar-t")
        XCTAssertEqual(listing, expected.map { $0.name + "\n" }.joined())
        let verbose = try ZipTestSupport.run("/usr/bin/bsdtar", ["-tvf", archive.path], in: directory, log: "bsdtar-tv")
        let lines = verbose.split(separator: "\n")
        XCTAssertEqual(lines.count, expected.count)
        for (line, item) in zip(lines, expected) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // 名前を保存すると root / wheel と表示される。数値の 0 が出ることも照合する。
            XCTAssertGreaterThanOrEqual(fields.count, 9, String(line))
            if fields.count >= 9 {
                XCTAssertEqual(fields[2], "0", String(line))
                XCTAssertEqual(fields[3], "0", String(line))
                XCTAssertEqual(UInt64(fields[4]), UInt64(item.data.count), String(line))
            }
            XCTAssertTrue(line.contains(item.name), String(line))
        }
        let script = """
        import json,sys,tarfile
        with tarfile.open(sys.argv[1]) as t:
            print(json.dumps([dict(name=m.name,size=m.size,uid=m.uid,gid=m.gid,uname=m.uname,gname=m.gname) for m in t],ensure_ascii=False))
        """
        let python = try ZipTestSupport.run("/usr/bin/python3", ["-c", script, archive.path], in: directory, log: "python-tarfile")
        let members = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(python.utf8)) as? [[String: Any]])
        XCTAssertEqual(members.count, expected.count)
        for (member, item) in zip(members, expected) {
            XCTAssertEqual(member["name"] as? String, item.kind == .directory ? String(item.name.dropLast()) : item.name)
            XCTAssertEqual((member["size"] as? NSNumber)?.uint64Value, UInt64(item.data.count))
            XCTAssertEqual(member["uid"] as? Int, 0)
            XCTAssertEqual(member["gid"] as? Int, 0)
            XCTAssertEqual(member["uname"] as? String, "")
            XCTAssertEqual(member["gname"] as? String, "")
        }
        let seven = try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", archive.path], in: directory, log: "7zz-t")
        XCTAssertTrue(seven.contains("Everything is Ok"), seven)
        XCTAssertFalse(seven.lowercased().contains("warning"), seven)
        if gzip {
            let result = try ZipTestSupport.run("/usr/bin/gzip", ["-t", archive.path], in: directory, log: "gzip-t")
            XCTAssertEqual(result, "")
        }
        let extracted = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let extraction = try ZipTestSupport.run("/usr/bin/bsdtar", [gzip ? "-xzf" : "-xf", archive.path, "-C", extracted.path],
                                                in: directory, log: "bsdtar-x")
        XCTAssertEqual(extraction, "")
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), expected.map(\.name))
        for (entry, item) in zip(reader.entries, expected) {
            XCTAssertEqual(entry.rawName.bytes, Array(item.name.utf8))
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), item.name)
            XCTAssertEqual(entry.posixPermissions, item.permissions, item.name)
            if let date = item.date { XCTAssertEqual(entry.modificationDate, date, item.name) }
            XCTAssertFalse(entry.isIncomplete)
            XCTAssertEqual(entry.formatSpecific["uid"], "0")
            XCTAssertEqual(entry.formatSpecific["gid"], "0")
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
            let file = extracted.appendingPathComponent(item.name)
            switch item.kind {
            case .file:
                XCTAssertEqual(try Data(contentsOf: file), item.data, item.name)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                if let date = item.date { XCTAssertEqual(attributes[.modificationDate] as? Date, date) }
            case .directory:
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
            case .symlink:
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), item.link)
                XCTAssertEqual(entry.formatSpecific["linkPath"], item.link)
            case .hardlink:
                let target = extracted.appendingPathComponent(try XCTUnwrap(item.link))
                let original = try FileManager.default.attributesOfItem(atPath: target.path)
                let linked = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual(linked[.systemFileNumber] as? NSNumber, original[.systemFileNumber] as? NSNumber)
                XCTAssertEqual(linked[.systemNumber] as? NSNumber, original[.systemNumber] as? NSNumber)
                XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: target))
                XCTAssertEqual(entry.formatSpecific["linkPath"], item.link)
                XCTAssertNotNil(entry.formatSpecific["hardLinkTargetIndex"])
            default: XCTFail("unexpected fixture kind")
            }
        }
    }
}

// 製品の serializer を使わず、512 byte ごとの配置と pax の byte 長を検査する。
struct TarBytes {
    struct Record {
        let offset: Int
        let header: Data
        let payload: Data
        var type: UInt8 { header[156] }
        var name: Data {
            let prefix = Data(header[345..<500].prefix { $0 != 0 })
            let name = Data(header[0..<100].prefix { $0 != 0 })
            return prefix.isEmpty ? name : prefix + Data([0x2F]) + name
        }
        var pax: [String: Data] {
            get throws {
                var fields: [String: Data] = [:]
                var start = 0
                while start < payload.count {
                    let space = try XCTUnwrap(payload[start...].firstIndex(of: 0x20))
                    let length = try XCTUnwrap(Int(String(decoding: payload[start..<space], as: UTF8.self)))
                    guard length > space - start + 1, start + length <= payload.count else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let end = start + length
                    XCTAssertEqual(payload[end - 1], 0x0A)
                    let equal = try XCTUnwrap(payload[(space + 1)..<(end - 1)].firstIndex(of: 0x3D))
                    let key = String(decoding: payload[(space + 1)..<equal], as: UTF8.self)
                    fields[key] = Data(payload[(equal + 1)..<(end - 1)])
                    start = end
                }
                return fields
            }
        }
    }

    let records: [Record]
    let endOffset: Int

    init(_ data: Data, blocking: Int = 10_240) throws {
        var offset = 0
        var records: [Record] = []
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            Self.checksum(header)
            let size = try XCTUnwrap(Int(String(decoding: header[124..<135], as: UTF8.self), radix: 8))
            guard size <= data.count - offset - 512 else { throw CocoaError(.fileReadCorruptFile) }
            let payload = data.subdata(in: (offset + 512)..<(offset + 512 + size))
            records.append(Record(offset: offset, header: header, payload: payload))
            let next = offset + 512 + ((size + 511) / 512) * 512
            XCTAssertTrue(data[(offset + 512 + size)..<next].allSatisfy { $0 == 0 })
            offset = next
        }
        self.records = records
        self.endOffset = offset
        XCTAssertGreaterThanOrEqual(data.count - offset, 1024)
        XCTAssertTrue(data[offset...].allSatisfy { $0 == 0 })
        XCTAssertEqual(data.count % blocking, 0)
    }

    static func checksum(_ header: Data) {
        XCTAssertEqual(header.count, 512)
        XCTAssertEqual(header[154], 0)
        XCTAssertEqual(header[155], 0x20)
        XCTAssertTrue(header[148..<154].allSatisfy { (0x30...0x37).contains($0) })
        let stored = UInt64(String(decoding: header[148..<154], as: UTF8.self), radix: 8)
        let actual = header.enumerated().reduce(UInt64(0)) { $0 + UInt64((148..<156).contains($1.offset) ? 0x20 : $1.element) }
        XCTAssertEqual(stored, actual)
        XCTAssertEqual(header[257..<265], Data("ustar\000".utf8))
    }
}
