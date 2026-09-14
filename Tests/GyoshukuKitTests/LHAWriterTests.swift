import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

@MainActor
final class LHAWriterTests: XCTestCase {
    func testRepetitiveMiBReallyCompresses() throws {
        let data = Data(repeating: 0x41, count: 1_048_576)
        let url = try archive("lha-repetitive", items: [.init(name: "repetitive.bin", data: data)])
        let bytes = try Data(contentsOf: url)
        XCTAssertLessThan(bytes.count, data.count / 10)
        XCTAssertEqual(try LHABytes(bytes).members.first?.method, "-lh5-")
        ZipTestSupport.report("LHA RATIO: \(data.count) bytes -> \(bytes.count) archive bytes")
        try LHATestSupport.verify(url, expected: [.init(name: "repetitive.bin", data: data)])
    }

    func testRandomDataFallsBackToStoredWithoutPayloadGrowth() throws {
        let data = LHATestSupport.random(131_071)
        let item = LHATestSupport.Expected(name: "random.bin", data: data)
        let url = try archive("lha-stored", items: [item])
        let bytes = try Data(contentsOf: url)
        let member = try XCTUnwrap(LHABytes(bytes).members.first)
        XCTAssertEqual(member.method, "-lh0-")
        XCTAssertEqual(member.payload, data)
        XCTAssertEqual(bytes.count, data.count + member.header.count + 1)
        try LHATestSupport.verify(url, expected: [item])
    }

    func testEmptyOneByteDictionarySizedAndLongRunFiles() throws {
        let items: [LHATestSupport.Expected] = [
            .init(name: "empty"), .init(name: "one", data: Data([0x9F])),
            .init(name: "8192", data: Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })),
            .init(name: "100000", data: Data(repeating: 0xEB, count: 100_000))
        ]
        let url = try archive("lha-edges", items: items)
        let members = try LHABytes(Data(contentsOf: url)).members
        XCTAssertEqual(members.map(\.method), ["-lh0-", "-lh0-", "-lh5-", "-lh5-"])
        try LHATestSupport.verify(url, expected: items)
    }

    func testUnrepresentableNamesAreRefusedBeforeReadingOrWriting() throws {
        let directory = try ZipTestSupport.directory("lha-unrepresentable")
        for (index, name) in ["emoji-🗂.txt", "한글.txt", "bad-🗂/file.txt"].enumerated() {
            let url = directory.appendingPathComponent("\(index).lzh")
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            // 拒否した writer の出力先だけでなく、同じ inode の別名にも有効な書庫を残さない。
            let alias = directory.appendingPathComponent("\(index)-alias.lzh")
            try FileManager.default.linkItem(at: url, to: alias)
            XCTAssertThrowsError(try LHARecords.Entry(name: name, mode: 0o100644, size: 0, date: ZipTestSupport.date))
            XCTAssertEqual(try Data(contentsOf: alias).count, 0)
            XCTAssertThrowsError(try writer.add(data: Data([1]), as: name)) {
                guard case .invalidPath = $0 as? WriterError else { return XCTFail("\($0)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: alias).count, 0)
            XCTAssertThrowsError(try writer.finish())
        }
    }

    func testSharedPathValidationAndConflictsRemovePartialOutput() throws {
        let directory = try ZipTestSupport.directory("lha-invalid-paths")
        let paths = ["", "/absolute", "../escape", "a/../b", "a/./b", "a//b", "a\\b", "C:drive", "nul\0name", "file/", String(repeating: "界", count: 22_000)]
        for (index, path) in paths.enumerated() {
            let url = directory.appendingPathComponent("\(index).lzh")
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try writer.add(data: Data([1]), as: "valid")
            XCTAssertThrowsError(try writer.add(data: Data(), as: path)) { XCTAssertEqual($0 as? WriterError, .invalidPath(path)) }
            XCTAssertThrowsError(try writer.finish())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        for (index, paths) in [["parent", "parent/child"], ["parent/child", "parent"], ["same", "same"], ["ガラス", "カ\u{3099}ラス"]].enumerated() {
            let url = directory.appendingPathComponent("conflict-\(index).lzh")
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try writer.add(data: Data(), as: paths[0])
            XCTAssertThrowsError(try writer.add(data: Data(), as: paths[1]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testTimestampBoundsAndSubseconds() throws {
        for value in [Double.nan, .infinity, -.infinity, -1, Double(UInt32.max) + 1] {
            XCTAssertThrowsError(try LHARecords.timestamp(Date(timeIntervalSince1970: value))) {
                XCTAssertEqual($0 as? WriterError, .invalidDate)
            }
        }
        XCTAssertEqual(try LHARecords.timestamp(Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(try LHARecords.timestamp(Date(timeIntervalSince1970: Double(UInt32.max))), UInt32.max)
        let directory = try ZipTestSupport.directory("lha-subseconds")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        try writer.add(data: Data([1]), as: "dated", modificationDate: ZipTestSupport.date.addingTimeInterval(0.9))
        try writer.finish()
        try LHATestSupport.verify(url, expected: [.init(name: "dated", data: Data([1]))])
    }

    func testHeaderSizePaddingAndLimits() throws {
        // 46 + 210 = 256。先頭が終端 byte にならないように、CRC 対象内へ一 byte 足す。
        let item = LHATestSupport.Expected(name: String(repeating: "n", count: 210), data: Data([1]))
        let url = try archive("lha-header-padding", items: [item])
        let member = try XCTUnwrap(LHABytes(Data(contentsOf: url)).members.first)
        XCTAssertEqual(member.header.count, 257)
        XCTAssertEqual(member.header[0], 1)
        try LHATestSupport.verify(url, expected: [item])
        XCTAssertThrowsError(try LHARecords.Entry(name: String(repeating: "n", count: 65_500), mode: 0o100644, size: 0, date: ZipTestSupport.date)) {
            XCTAssertEqual($0 as? WriterError, .sizeOverflow)
        }
        XCTAssertThrowsError(try LHARecords.Entry(name: "large", mode: 0o100644, size: UInt64(UInt32.max) + 1, date: ZipTestSupport.date)) {
            XCTAssertEqual($0 as? WriterError, .sizeOverflow)
        }
    }

    func testDiskRecursionAndExecutableMode() throws {
        let directory = try ZipTestSupport.directory("lha-disk")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("run")
        let payload = Data("#!/bin/sh\nexit 0\n".utf8)
        try payload.write(to: file)
        for url in [file, source, source.appendingPathComponent("empty")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: ZipTestSupport.date], ofItemAtPath: url.path)
        }
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        try writer.add(contentsOf: source, as: "tree")
        try writer.finish()
        try LHATestSupport.verify(url, expected: [
            .init(name: "tree/", kind: .directory, mode: 0o755),
            .init(name: "tree/empty/", kind: .directory, mode: 0o755),
            .init(name: "tree/run", data: payload, mode: 0o755)
        ])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("lha-extracted/tree/run").path))
    }

    func testSimpleArchiveExternalDecodersAndKaito() throws {
        let directory = try ZipTestSupport.directory("lha-simple")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        let payload = Data(String(repeating: "LHA static Huffman\n", count: 1000).utf8)
        try writer.add(data: payload, as: "dir/sub/file.txt", modificationDate: ZipTestSupport.date, permissions: 0o755)
        try writer.add(data: Data(), as: "empty", modificationDate: ZipTestSupport.date)
        try writer.addDirectory("folder")
        try writer.finish()
        let bytes = try LHABytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.members.map(\.method), ["-lh5-", "-lh0-", "-lhd-"])
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), ["dir/sub/file.txt", "empty", "folder/"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        XCTAssertEqual(bytes.members[0].extensions[1], Data("file.txt".utf8))
        XCTAssertEqual(bytes.members[0].extensions[2], Data([0x64, 0x69, 0x72, 0xFF, 0x73, 0x75, 0x62, 0xFF]))
        XCTAssertEqual(bytes.members[2].extensions[1], Data())
        XCTAssertEqual(bytes.members[2].extensions[2], Data("folder".utf8) + Data([0xFF]))
        try LHATestSupport.verify(url, expected: [
            .init(name: "dir/sub/file.txt", data: payload, mode: 0o755),
            .init(name: "empty"),
            .init(name: "folder/", kind: .directory, mode: 0o755, date: nil)
        ])
    }

    func testJapaneseNamesAreCP932() throws {
        let directory = try ZipTestSupport.directory("lha-japanese")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        let items: [LHATestSupport.Expected] = [
            .init(name: "ascii.txt", data: Data("ASCII control\n".utf8)),
            .init(name: "日本語.txt", data: Data("Japanese\n".utf8)),
            .init(name: "ガラス/①髙～.txt", data: Data([1, 2, 3])),
            .init(name: "dir/sub/file.txt", data: Data(repeating: 0x41, count: 1000))
        ]
        for item in items {
            try writer.add(data: item.data, as: item.name.decomposedStringWithCanonicalMapping, modificationDate: item.date)
        }
        try writer.finish()
        let members = try LHABytes(Data(contentsOf: url)).members
        let member = members[1]
        XCTAssertEqual(member.extensions[1], Data([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x2E, 0x74, 0x78, 0x74]))
        XCTAssertEqual(members[2].extensions[1], try XCTUnwrap("①髙～.txt".data(using: .shiftJIS)))
        XCTAssertEqual(members[2].extensions[2], try XCTUnwrap("ガラス".data(using: .shiftJIS)) + Data([0xFF]))
        XCTAssertTrue(members.allSatisfy { $0.extensions[0x46] == nil })
        // macOS の Lhasa 0.6.0 は CP932 名の表示を置換し、展開も Failure になる。
        // 7zz 26.03 もここでは CP932 名を復元しない。名前は raw byte と KaitoKit で検証し、
        // 同じ書庫の ASCII member は三実装で展開して構造・内容を照合する。
        try LHATestSupport.verify(url, expected: items, externalNames: ["ascii.txt", "dir/sub/file.txt"])
    }

    private func archive(_ label: String, items: [LHATestSupport.Expected]) throws -> URL {
        let directory = try ZipTestSupport.directory(label)
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        XCTAssertEqual(writer.format, .lha)
        for item in items {
            try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.mode)
        }
        try writer.finish()
        return url
    }
}
