import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipWriterTests: XCTestCase {
    func testEmptyArchive() throws {
        let directory = try ZipTestSupport.directory("empty")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.finish()
        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: url).count, 22)
        try ZipTestSupport.verify(url, expected: [])
        let oracle = directory.appendingPathComponent("python-empty.zip")
        try ZipTestSupport.run("/usr/bin/python3", ["-c", "import sys,zipfile; zipfile.ZipFile(sys.argv[1],'w').close()", oracle.path], in: directory, log: "python-create")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: oracle))
        let result = try ZipTestSupport.run("/usr/bin/ditto", ["-x", "-k", oracle.path, directory.appendingPathComponent("python-ditto").path], in: directory, log: "python-ditto-x", allowed: [1])
        XCTAssertEqual(result, "ditto: Incorrect pkzip signature\n")
    }

    func testSingleSmallFileStoredAndDeflated() throws {
        for method in [CompressionMethod.stored, .deflate] {
            let directory = try ZipTestSupport.directory("single-\(method)")
            let url = directory.appendingPathComponent("archive.zip")
            let payload = Data("123456789".utf8)
            let writer = try ArchiveWriter.create(url: url, options: WriterOptions(compressionMethod: method))
            try writer.add(data: payload, as: "small.txt", modificationDate: ZipTestSupport.date)
            try writer.finish()
            let bytes = ZipBytes(data: try Data(contentsOf: url))
            XCTAssertEqual(bytes.u16(8), method.rawValue)
            XCTAssertEqual(bytes.u32(14), 0xCBF43926)
            XCTAssertEqual(bytes.u16(6), 0x0800)
            XCTAssertEqual(bytes.u16(bytes.central + 4), 0x033F)
            XCTAssertEqual(bytes.u32(bytes.central + 38), 0x81A40000)
            // payload の直後が central。descriptor は存在しない。
            XCTAssertEqual(30 + Int(bytes.u16(26)) + Int(bytes.u16(28)) + Int(bytes.u32(18)), bytes.central)
            try ZipTestSupport.verify(url, expected: [.init(name: "small.txt", data: payload)])
        }
    }

    func testZeroByteFileUsesStoredWithoutPayload() throws {
        let directory = try ZipTestSupport.directory("zero")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(data: Data(), as: "zero", modificationDate: ZipTestSupport.date)
        try writer.finish()
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(bytes.u16(8), 0)
        XCTAssertEqual(bytes.u32(14), 0)
        XCTAssertEqual(bytes.u32(18), 0)
        XCTAssertEqual(bytes.u32(22), 0)
        XCTAssertEqual(30 + Int(bytes.u16(26)) + Int(bytes.u16(28)), bytes.central)
        try ZipTestSupport.verify(url, expected: [.init(name: "zero")])
    }

    func testJapaneseUTF8NFCAndTimestampExtraLengths() throws {
        let directory = try ZipTestSupport.directory("japanese")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        let nfc = "日本語/ガラス.txt"
        let payload = Data("こんにちは\n".utf8)
        try writer.add(data: payload, as: nfc.decomposedStringWithCanonicalMapping, modificationDate: ZipTestSupport.date)
        try writer.finish()
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(bytes.u16(6), 1 << 11)
        XCTAssertEqual(bytes.u16(bytes.central + 8), 1 << 11)
        XCTAssertEqual(bytes.data.subdata(in: 30..<(30 + Int(bytes.u16(26)))), Data(nfc.utf8))
        let local = try XCTUnwrap(bytes.extras(0, local: true)[0x5455])
        let central = try XCTUnwrap(bytes.extras(bytes.central, local: false)[0x5455])
        XCTAssertEqual(local.count, 9)
        XCTAssertEqual(central.count, 5)
        XCTAssertEqual(local[0], 3)
        XCTAssertEqual(central[0], 1)
        XCTAssertEqual(ZipBytes(data: local).u32(1), 1_700_000_001)
        XCTAssertEqual(ZipBytes(data: local).u32(5), 1_700_000_001)
        XCTAssertEqual(ZipBytes(data: central).u32(1), 1_700_000_001)
        XCTAssertNil(bytes.extras(0, local: true)[0x7875])
        try ZipTestSupport.verify(url, expected: [.init(name: nfc, data: payload)])
    }

    func testDirectoryTreePermissionsAndSymlink() throws {
        let directory = try ZipTestSupport.directory("tree")
        let source = directory.appendingPathComponent("source")
        let sub = source.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plain = Data("plain file\n".utf8)
        let executable = Data("#!/bin/sh\necho 凝縮\n".utf8)
        try plain.write(to: source.appendingPathComponent("plain.txt"))
        try executable.write(to: sub.appendingPathComponent("run.sh"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "plain.txt")
        for (url, mode) in [(source, 0o755), (sub, 0o755), (source.appendingPathComponent("plain.txt"), 0o644), (sub.appendingPathComponent("run.sh"), 0o755)] {
            try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: ZipTestSupport.date], ofItemAtPath: url.path)
        }
        // symlink 自体の時刻を取得し、target の内容・mode と混同しない。
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: source.appendingPathComponent("link").path)
        let linkDate = Date(timeIntervalSince1970: floor((linkAttributes[.modificationDate] as! Date).timeIntervalSince1970))
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(contentsOf: source, as: "tree")
        let before = Date()
        try writer.addDirectory("empty-dir")
        try writer.finish()
        let reader = try ArchiveReader.open(url: url)
        let emptyDate = try XCTUnwrap(reader.entries.last?.modificationDate)
        XCTAssertLessThan(abs(emptyDate.timeIntervalSince(before)), 2)
        let expected: [ZipTestSupport.Expected] = [
            .init(name: "tree/", kind: .directory, permissions: 0o755),
            .init(name: "tree/link", data: Data("plain.txt".utf8), kind: .symlink, permissions: 0o755, date: linkDate),
            .init(name: "tree/plain.txt", data: plain),
            .init(name: "tree/sub/", kind: .directory, permissions: 0o755),
            .init(name: "tree/sub/run.sh", data: executable, permissions: 0o755),
            .init(name: "empty-dir/", kind: .directory, permissions: 0o755, date: emptyDate)
        ]
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        var offset = bytes.central
        for item in expected {
            let mode = bytes.u32(offset + 38)
            if item.kind == .symlink { XCTAssertEqual(mode >> 16, 0xA1ED) }
            if item.kind == .directory {
                XCTAssertEqual(mode & 0xFF, 0x10)
                XCTAssertEqual(bytes.u16(offset + 10), 0)
                XCTAssertEqual(bytes.u32(offset + 16), 0)
                XCTAssertEqual(bytes.u32(offset + 20), 0)
                XCTAssertEqual(bytes.u32(offset + 24), 0)
            }
            offset += 46 + Int(bytes.u16(offset + 28)) + Int(bytes.u16(offset + 30))
        }
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testCompressionLevelsHeuristicAndOwnerOptIn() throws {
        for level in [0, 1, 6, 9] {
            let directory = try ZipTestSupport.directory("level-\(level)")
            let url = directory.appendingPathComponent("archive.zip")
            let payload = Data(repeating: 0x41, count: 800_001)
            let source = directory.appendingPathComponent("source")
            try payload.write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .modificationDate: ZipTestSupport.date], ofItemAtPath: source.path)
            let writer = try ArchiveWriter.create(url: url, options: WriterOptions(deflateLevel: level, useCompressionHeuristic: false, preserveOwnerIDs: true))
            try writer.add(contentsOf: source, as: "payload.png")
            try writer.finish()
            let bytes = ZipBytes(data: try Data(contentsOf: url))
            XCTAssertEqual(bytes.u16(8), 8)
            let owner = ZipBytes(data: try XCTUnwrap(bytes.extras(0, local: true)[0x7875]))
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            XCTAssertEqual(owner.u32(2), (attributes[.ownerAccountID] as! NSNumber).uint32Value)
            XCTAssertEqual(owner.u32(7), (attributes[.groupOwnerAccountID] as! NSNumber).uint32Value)
            if level == 0 { XCTAssertGreaterThan(bytes.u32(18), UInt32(payload.count)) }
            else { XCTAssertLessThan(bytes.u32(18), 10_000) }
            try ZipTestSupport.verify(url, expected: [.init(name: "payload.png", data: payload)])
        }
        let directory = try ZipTestSupport.directory("heuristic")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        let payload = Data(repeating: 1, count: 1_001)
        try writer.add(data: payload, as: "photo.JPG", modificationDate: ZipTestSupport.date)
        try writer.finish()
        XCTAssertEqual(ZipBytes(data: try Data(contentsOf: url)).u16(8), 0)
        try ZipTestSupport.verify(url, expected: [.init(name: "photo.JPG", data: payload)])
    }

    func testInvalidInputsAndWriterLifecycle() throws {
        let directory = try ZipTestSupport.directory("invalid")
        let url = directory.appendingPathComponent("archive.zip")
        XCTAssertThrowsError(try ArchiveWriter.create(url: url, options: WriterOptions(deflateLevel: 10)))
        XCTAssertThrowsError(try ArchiveWriter.create(url: url, options: WriterOptions(preserveMacOSMetadata: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for (index, name) in ["", "/absolute", "../escape", "a/../b", "a//b", "a\\b", "C:drive", "nul\0name", "file/", String(repeating: "界", count: 22_000)].enumerated() {
            let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("invalid-\(index).zip"))
            XCTAssertThrowsError(try writer.add(data: Data(), as: name))
            XCTAssertThrowsError(try writer.finish())
        }
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(data: Data(), as: "ガ", modificationDate: ZipTestSupport.date)
        XCTAssertThrowsError(try writer.add(data: Data(), as: "カ\u{3099}"))
        XCTAssertThrowsError(try writer.finish())
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try ArchiveWriter.create(url: url))
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let finishedURL = directory.appendingPathComponent("finished.zip")
        let finished = try ArchiveWriter.create(url: finishedURL)
        try finished.finish()
        XCTAssertThrowsError(try finished.addDirectory("late"))
        try ZipTestSupport.verify(finishedURL, expected: [])
    }

    func testDOSDateAndTimestampBounds() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let value = ZipRecords.dosDate(ZipTestSupport.date, timeZone: utc)
        XCTAssertEqual(value.time, UInt16((22 << 11) | (13 << 5) | 10))
        XCTAssertEqual(value.date, UInt16((43 << 9) | (11 << 5) | 14))
        XCTAssertEqual(ZipRecords.dosDate(Date(timeIntervalSince1970: 0), timeZone: utc).date, 0x21)
        XCTAssertEqual(ZipRecords.dosDate(Date(timeIntervalSince1970: 5_000_000_000), timeZone: utc).date, 0xFF9F)
        XCTAssertEqual(try ZipRecords.timestamp(Date(timeIntervalSince1970: -1)), UInt32.max)
        XCTAssertThrowsError(try ZipRecords.timestamp(Date(timeIntervalSince1970: Double.infinity)))
        XCTAssertThrowsError(try ZipRecords.timestamp(Date(timeIntervalSince1970: Double(Int32.max) + 1)))
    }

    func testRejectsFileDirectoryConflictsAndOutputAsSource() throws {
        let directory = try ZipTestSupport.directory("conflicts")
        for (index, paths) in [["parent", "parent/child"], ["parent/child", "parent"]].enumerated() {
            let writer = try ArchiveWriter.create(url: directory.appendingPathComponent("conflict-\(index).zip"))
            try writer.add(data: Data(), as: paths[0])
            XCTAssertThrowsError(try writer.add(data: Data(), as: paths[1]))
            XCTAssertThrowsError(try writer.finish())
        }
        let url = directory.appendingPathComponent("self.zip")
        let writer = try ArchiveWriter.create(url: url)
        XCTAssertThrowsError(try writer.add(contentsOf: url, as: "self"))
        XCTAssertThrowsError(try writer.finish())
    }

    func testDanglingSymlinkAndSlicedDataRoundTrip() throws {
        let directory = try ZipTestSupport.directory("dangling")
        let source = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let date = Date(timeIntervalSince1970: floor((attributes[.modificationDate] as! Date).timeIntervalSince1970))
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(contentsOf: source, as: "link")
        let data = Data([0, 1, 2, 3, 4]).dropFirst(2)
        XCTAssertNotEqual(data.startIndex, 0)
        try writer.add(data: data, as: "slice", modificationDate: ZipTestSupport.date, permissions: 0o755)
        try writer.finish()
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(bytes.u16(8), 0)
        XCTAssertEqual(bytes.u32(bytes.central + 38) >> 16, 0xA1ED)
        try ZipTestSupport.verify(url, expected: [
            .init(name: "link", data: Data("missing".utf8), kind: .symlink, permissions: 0o755, date: date),
            .init(name: "slice", data: Data([2, 3, 4]), permissions: 0o755)
        ])
    }
}
