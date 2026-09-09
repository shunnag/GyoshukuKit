import Foundation
import Darwin
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipUpdaterTests: XCTestCase {
    private let payload = Data("old entry: unchanged compressed bytes\n".utf8)
    private let added = Data("new entry: 凝縮\n".utf8)

    private func original(_ label: String) throws -> URL {
        let directory = try ZipTestSupport.directory(label)
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(data: payload, as: "old.txt", modificationDate: ZipTestSupport.date)
        try writer.finish()
        return url
    }

    private func append(_ url: URL) throws {
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(data: added, as: "new.txt", modificationDate: ZipTestSupport.date, permissions: 0o755)
        try updater.commit()
        try updater.commit()
        XCTAssertThrowsError(try updater.addDirectory("late"))
    }

    private var expected: [ZipTestSupport.Expected] {
        [.init(name: "old.txt", data: payload), .init(name: "new.txt", data: added, permissions: 0o755)]
    }

    private func assertPreserved(_ old: Data, in url: URL, commentLength: Int = 0) throws {
        let before = ZipBytes(data: old)
        let after = ZipBytes(data: try Data(contentsOf: url))
        let oldEnd = old.count - 22 - commentLength
        let oldCentral = Int(before.u32(oldEnd + 16))
        let oldSize = Int(before.u32(oldEnd + 12))
        let newEnd = after.data.count - 22 - commentLength
        let newCentral = Int(after.u32(newEnd + 16))
        XCTAssertEqual(after.data.prefix(oldCentral), old.prefix(oldCentral))
        XCTAssertEqual(after.data.subdata(in: newCentral..<(newCentral + oldSize)),
                       old.subdata(in: oldCentral..<(oldCentral + oldSize)))
    }

    func testAppendWriterArchiveSharesExactRecordBytes() throws {
        let url = try original("update-writer")
        let old = try Data(contentsOf: url)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(data: added, as: "new.txt", modificationDate: ZipTestSupport.date, permissions: 0o755)
        XCTAssertEqual(try Data(contentsOf: url), old)
        try updater.commit()
        try assertPreserved(old, in: url)
        let oracle = url.deletingLastPathComponent().appendingPathComponent("writer.zip")
        let writer = try ArchiveWriter.create(url: oracle)
        try writer.add(data: payload, as: "old.txt", modificationDate: ZipTestSupport.date)
        try writer.add(data: added, as: "new.txt", modificationDate: ZipTestSupport.date, permissions: 0o755)
        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: oracle))
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testAppendDiskTreeAndDirectory() throws {
        let url = try original("update-tree")
        let source = url.deletingLastPathComponent().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("run.sh")
        try added.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: ZipTestSupport.date], ofItemAtPath: file.path)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "run.sh")
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        let linkDate = Date(timeIntervalSince1970: floor((attrs[.modificationDate] as! Date).timeIntervalSince1970))
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: ZipTestSupport.date], ofItemAtPath: source.path)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(contentsOf: source, as: "tree")
        let before = Date()
        try updater.addDirectory("empty")
        try updater.commit()
        let date = try XCTUnwrap(ArchiveReader.open(url: url).entries.last?.modificationDate)
        XCTAssertLessThan(abs(date.timeIntervalSince(before)), 2)
        try ZipTestSupport.verify(url, expected: [
            .init(name: "old.txt", data: payload),
            .init(name: "tree/", kind: .directory, permissions: 0o755),
            .init(name: "tree/link", data: Data("run.sh".utf8), kind: .symlink, permissions: 0o755, date: linkDate),
            .init(name: "tree/run.sh", data: added, permissions: 0o755),
            .init(name: "empty/", kind: .directory, permissions: 0o755, date: date)
        ])
    }

    func testAppendDittoDataDescriptorsAndInfoZIP() throws {
        for tool in ["ditto", "infozip"] {
            let directory = try ZipTestSupport.directory("update-\(tool)")
            let source = directory.appendingPathComponent("old.txt")
            let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
            try payload.write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .modificationDate: sourceDate], ofItemAtPath: source.path)
            let url = directory.appendingPathComponent("archive.zip")
            if tool == "ditto" {
                try ZipTestSupport.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", source.path, url.path], in: directory, log: "create")
            } else {
                try ZipTestSupport.run("/usr/bin/zip", ["-j", url.path, source.path], in: directory, log: "create")
            }
            let old = try Data(contentsOf: url)
            let bytes = ZipBytes(data: old)
            if tool == "ditto" {
                XCTAssertEqual(bytes.u16(8), 8)
                XCTAssertEqual(bytes.u16(6) & 8, 8)
                XCTAssertEqual(bytes.u16(bytes.central + 8) & 8, 8)
                // descriptor の探索はしない。CD より前が全 byte 同一なら descriptor も保存される。
            }
            try append(url)
            try assertPreserved(old, in: url)
            var items = expected
            items[0].date = sourceDate
            try ZipTestSupport.verify(url, expected: items)
        }
    }

    func testAppendCP932PreservesRawNamesAndFlags() throws {
        let directory = try ZipTestSupport.directory("update-cp932")
        let url = directory.appendingPathComponent("archive.zip")
        // 公開 ZIP byte 表だけで構築。CP932 の名前を zipfile に UTF-8 へ変換させない。
        let script = #"""
        import struct, zlib, sys
        p = lambda f,*v: struct.pack('<'+f,*v)
        name = '日本語.txt'.encode('cp932')
        data = b'CP932 original\n'
        crc = zlib.crc32(data)
        ts = p('HHBI',0x5455,5,1,1700000001)
        local = p('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(ts))+name+ts+data
        cd = p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(ts),0,0,0,0o100644<<16,0)+name+ts
        end = p('IHHHHIIH',0x06054b50,0,0,1,1,len(cd),len(local),0)
        open(sys.argv[1],'wb').write(local+cd+end)
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-create")
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["l", "-slt", "-mcp=932", url.path], in: directory, log: "original-7zz-l")
        let old = try Data(contentsOf: url)
        let legacy = ZipBytes(data: old)
        let rawName = old.subdata(in: (legacy.central + 46)..<(legacy.central + 46 + Int(legacy.u16(legacy.central + 28))))
        XCTAssertEqual(rawName, Data([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x2E, 0x74, 0x78, 0x74]))
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(data: added, as: "追加/カ\u{3099}ラス.txt", modificationDate: ZipTestSupport.date)
        try updater.commit()
        try assertPreserved(old, in: url)
        let updated = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(updated.u16(updated.central + 8), 0)
        let next = updated.central + Int(legacy.u32(legacy.end + 12))
        XCTAssertEqual(updated.u16(next + 8), 1 << 11)
        XCTAssertEqual(updated.data.subdata(in: (next + 46)..<(next + 46 + Int(updated.u16(next + 28)))), Data("追加/ガラス.txt".utf8))
        try ZipTestSupport.verify(url, expected: [
            .init(name: "日本語.txt", data: Data("CP932 original\n".utf8)),
            .init(name: "追加/ガラス.txt", data: added)
        ], legacyCP932: true)
    }

    private func assertGate(_ gate: UpdateGatekeeper, transform: (Data) -> Data) throws {
        let url = try original("update-gate-\(gate.rawValue)")
        let fixture = transform(try Data(contentsOf: url))
        try fixture.write(to: url)
        // reader の列挙は引き続き可能。壊れた offset の payload が読めるという主張はしない。
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), ["old.txt"])
        if gate != .centralDirectoryOffset {
            XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), payload)
        }
        XCTAssertThrowsError(try ArchiveUpdater.open(url: url)) {
            XCTAssertEqual($0 as? UpdaterError, .editingRefused(gatekeeper: gate, reason: gate.reason))
        }
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }

    func testGatekeeperSFXPrefixLeavesOriginalUntouched() throws {
        try assertGate(.sfxPrefix) { archive in
            // PE の公開 magic と e_lfanew だけを持つ、実行しない prefix。
            var prefix = Data(repeating: 0, count: 128)
            prefix[0] = 0x4D
            prefix[1] = 0x5A
            prefix[0x3C] = 64
            prefix[64] = 0x50
            prefix[65] = 0x45
            return prefix + archive
        }
    }

    func testGatekeeperTrailingDataLeavesOriginalUntouched() throws {
        try assertGate(.trailingData) { $0 + Data("trailing data".utf8) }
    }

    func testGatekeeperTruncatedCDOffsetLeavesOriginalUntouched() throws {
        try assertGate(.centralDirectoryOffset) { data in
            var result = data
            // 4 GiB の実データを作らず、EOCD offset の上位 bit を手で切り詰める。
            let end = data.count - 22
            let wrong = ZipBytes(data: data).u32(end + 16) & 0x0F
            var encoded = Data()
            encoded.le(wrong)
            result.replaceSubrange((end + 16)..<(end + 20), with: encoded)
            return result
        }
    }

    func testAppendCrossesZIP64CountAndUpdatesZIP64Again() throws {
        let directory = try ZipTestSupport.directory("update-zip64-count")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        var expected: [ZipTestSupport.Expected] = []
        for index in 0..<65_530 {
            let name = String(format: "entry-%05d", index)
            try writer.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
            expected.append(.init(name: name))
        }
        try writer.finish()
        let old = try Data(contentsOf: url)
        let before = ZipBytes(data: old)
        XCTAssertEqual(before.u16(before.end + 10), 65_530)
        XCTAssertNotEqual(before.u32(before.end - 20), 0x07064B50)
        let updater = try ArchiveUpdater.open(url: url)
        for index in 65_530..<65_540 {
            let name = String(format: "entry-%05d", index)
            try updater.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
            expected.append(.init(name: name))
        }
        try updater.commit()
        try assertPreserved(old, in: url)
        let after = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(after.u16(after.end + 10), 65_535)
        XCTAssertEqual(after.u32(after.end - 20), 0x07064B50)
        let zip64 = Int(after.u64(after.end - 12))
        XCTAssertEqual(after.u32(zip64), 0x06064B50)
        XCTAssertEqual(after.u64(zip64 + 32), 65_540)
        try ZipTestSupport.verify(url, expected: expected)
        let listing = try String(contentsOf: directory.appendingPathComponent("unzip-l.log"), encoding: .utf8)
        XCTAssertTrue(listing.contains("65540 files"))
        let seven = try String(contentsOf: directory.appendingPathComponent("7zz-t.log"), encoding: .utf8)
        XCTAssertTrue(seven.contains("Files: 65540"))
        ZipTestSupport.report("KAITO UPDATE ZIP64 count=65540; all names, bytes, dates, permissions and CRCs verified")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ditto"))
        // 既存 ZIP64 の locator を読む経路も別の完成書庫で往復する。
        let secondDirectory = try ZipTestSupport.directory("update-existing-zip64")
        let second = secondDirectory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: url, to: second)
        let again = try ArchiveUpdater.open(url: second)
        try again.add(data: added, as: "new.txt", modificationDate: ZipTestSupport.date)
        try again.commit()
        try assertPreserved(after.data, in: second)
        expected.append(.init(name: "new.txt", data: added))
        try ZipTestSupport.verify(second, expected: expected)
        try FileManager.default.removeItem(at: secondDirectory.appendingPathComponent("ditto"))
    }

    func testCommitPreservesModeQuarantineXattrsAndCreationDate() throws {
        let url = try original("update-metadata")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o651], ofItemAtPath: url.path)
        let quarantine = Data("0081;6553f101;GyoshukuKit;01234567-89AB-CDEF-0123-456789ABCDEF".utf8)
        let tag = try PropertyListSerialization.data(fromPropertyList: ["凝縮\n2"], format: .binary, options: 0)
        for (name, data) in [("com.apple.quarantine", quarantine), ("com.example.GyoshukuKit", payload), ("com.apple.metadata:_kMDItemUserTags", tag)] {
            XCTAssertEqual(data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }, 0)
        }
        let creation = try manager.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        try append(url)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o651)
        XCTAssertEqual(attributes[.creationDate] as? Date, creation)
        for (name, data) in [("com.apple.quarantine", quarantine), ("com.example.GyoshukuKit", payload), ("com.apple.metadata:_kMDItemUserTags", tag)] {
            var buffer = Data(count: 1024)
            let count = buffer.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
            XCTAssertEqual(count, data.count, name)
            if count >= 0 { XCTAssertEqual(buffer.prefix(count), data, name) }
        }
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testFailureAbandonmentAndConcurrentChangePreserveOriginal() throws {
        let url = try original("update-safety")
        let old = try Data(contentsOf: url)
        do {
            let updater = try ArchiveUpdater.open(url: url)
            try updater.add(data: added, as: "discard.txt")
        }
        XCTAssertEqual(try Data(contentsOf: url), old)
        for path in ["old.txt", "old.txt/child", "../escape"] {
            let updater = try ArchiveUpdater.open(url: url)
            XCTAssertThrowsError(try updater.add(data: added, as: path))
            XCTAssertThrowsError(try updater.commit())
            XCTAssertEqual(try Data(contentsOf: url), old)
        }
        let noOp = try ArchiveUpdater.open(url: url)
        try noOp.commit()
        try noOp.commit()
        XCTAssertEqual(try Data(contentsOf: url), old)
        let loser = try ArchiveUpdater.open(url: url)
        try loser.add(data: Data(), as: "loser")
        try append(url)
        let winner = try Data(contentsOf: url)
        XCTAssertThrowsError(try loser.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        XCTAssertEqual(try Data(contentsOf: url), winner)
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testEmptyArchiveAndCommentSurviveAppend() throws {
        for kind in ["true", "false", "zip64-empty"] {
            let empty = kind != "false"
            let url = try original("update-comment-\(kind)")
            if empty {
                try FileManager.default.removeItem(at: url)
                try ArchiveWriter.create(url: url).finish()
            }
            if kind == "zip64-empty" {
                // entry が 0 件でも ZIP64 終端を持つ正当な空書庫。
                let script = #"""
                import struct,sys
                p=lambda f,*v:struct.pack('<'+f,*v)
                z=p('IQHHIIQQQQ',0x06064b50,44,0x032d,45,0,0,0,0,0,0)
                l=p('IIQI',0x07064b50,0,0,1)
                e=p('IHHHHIIH',0x06054b50,0,0,0,0,0,0,0)
                open(sys.argv[1],'wb').write(z+l+e)
                """#
                try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path],
                                       in: url.deletingLastPathComponent(), log: "python-create")
            }
            let comment = Data("ZIP comment: 保存\n".utf8)
            var bytes = try Data(contentsOf: url)
            var length = Data()
            length.le(UInt16(comment.count))
            bytes.replaceSubrange((bytes.count - 2)..<bytes.count, with: length)
            bytes.append(comment)
            try bytes.write(to: url)
            try append(url)
            try assertPreserved(bytes, in: url, commentLength: comment.count)
            XCTAssertEqual(try Data(contentsOf: url).suffix(comment.count), comment)
            try ZipTestSupport.verify(url, expected: empty ? Array(expected.suffix(1)) : expected)
        }
    }
}
