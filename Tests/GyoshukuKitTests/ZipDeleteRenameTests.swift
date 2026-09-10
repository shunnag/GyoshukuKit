import Foundation
import Darwin
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipDeleteRenameTests: XCTestCase {
    private func original(_ label: String, count: Int = 5) throws -> (URL, [ZipTestSupport.Expected]) {
        let directory = try ZipTestSupport.directory(label)
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        let items = (0..<count).map { index in
            ZipTestSupport.Expected(name: "entry-\(index).txt",
                data: Data(String(repeating: "保存する payload \(index)\n", count: 41 + index).utf8),
                permissions: index % 2 == 0 ? 0o755 : 0o640)
        }
        for item in items {
            try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.permissions)
        }
        try writer.finish()
        return (url, items)
    }

    private struct Snapshot {
        let bytes: Data
        let entries: [ArchiveEntry]
        let records: [RawEntryRecord]

        init(_ url: URL) throws {
            bytes = try Data(contentsOf: url)
            let reader = try ArchiveReader.open(url: url)
            entries = reader.entries
            records = try entries.map { try XCTUnwrap(reader.rawRecord(of: $0)) }
        }

        func data(_ range: Range<UInt64>) -> Data { bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    }

    private func assertCarried(_ before: Snapshot, to url: URL, indices: [Int], renamed: Set<Int> = []) throws {
        let after = try Snapshot(url)
        XCTAssertGreaterThanOrEqual(after.entries.count, indices.count)
        for (newIndex, oldIndex) in indices.enumerated() {
            let old = before.records[oldIndex], new = after.records[newIndex]
            XCTAssertEqual(after.data(new.payloadRange), before.data(old.payloadRange), "圧縮 payload \(oldIndex)")
            XCTAssertEqual(after.data(new.payloadRange.upperBound..<new.recordRange.upperBound),
                           before.data(old.payloadRange.upperBound..<old.recordRange.upperBound), "descriptor \(oldIndex)")
            if !renamed.contains(oldIndex) {
                XCTAssertEqual(after.data(new.recordRange), before.data(old.recordRange), "local record \(oldIndex)")
                XCTAssertEqual(after.entries[newIndex].rawName, before.entries[oldIndex].rawName)
                XCTAssertEqual(after.entries[newIndex].formatSpecific["flags"], before.entries[oldIndex].formatSpecific["flags"])
            }
            XCTAssertEqual(after.entries[newIndex].crc32, before.entries[oldIndex].crc32)
            XCTAssertEqual(after.entries[newIndex].modificationDate, before.entries[oldIndex].modificationDate)
            XCTAssertEqual(after.entries[newIndex].posixPermissions, before.entries[oldIndex].posixPermissions)
            XCTAssertEqual(after.entries[newIndex].compressedSize, before.entries[oldIndex].compressedSize)
            if newIndex > 0 { XCTAssertEqual(new.recordRange.lowerBound, after.records[newIndex - 1].recordRange.upperBound) }
        }
    }

    func testDeleteFirstMiddleLastAndSeveralPreservesRawRecords() throws {
        for deleted in [[0], [2], [4], [0, 2, 4]] {
            let (url, items) = try original("delete-" + deleted.map(String.init).joined(separator: "-"))
            let before = try Snapshot(url)
            let updater = try ArchiveUpdater.open(url: url)
            try updater.remove(entriesAt: deleted + deleted)
            XCTAssertEqual(try Data(contentsOf: url), before.bytes)
            try updater.commit()
            let kept = items.indices.filter { !deleted.contains($0) }
            try assertCarried(before, to: url, indices: kept)
            try ZipTestSupport.verify(url, expected: kept.map { items[$0] })
        }
    }

    func testRenameShorterEqualLongerAndJapanesePatchesBothHeaders() throws {
        for (label, name) in [("shorter", "x"), ("equal", "other-1.txt"),
                              ("longer", "a-much-longer-file-name.txt"), ("japanese", "日本語/カ\u{3099}ラス.txt")] {
            let (url, items) = try original("rename-\(label)")
            let before = try Snapshot(url)
            let updater = try ArchiveUpdater.open(url: url)
            try updater.rename(entryAt: 1, to: name)
            XCTAssertEqual(try Data(contentsOf: url), before.bytes)
            try updater.commit()
            let after = try Snapshot(url)
            let nfc = name.precomposedStringWithCanonicalMapping
            let delta = nfc.utf8.count - items[1].name.utf8.count
            let local = Int(after.records[1].recordRange.lowerBound)
            let bytes = ZipBytes(data: after.bytes)
            XCTAssertEqual(bytes.u16(local + 6) & 0x0800, 0x0800)
            XCTAssertEqual(bytes.u16(local + 26), UInt16(nfc.utf8.count))
            XCTAssertEqual(after.bytes.subdata(in: (local + 30)..<(local + 30 + nfc.utf8.count)), Data(nfc.utf8))
            XCTAssertEqual(after.entries[1].rawName.bytes, Array(nfc.utf8))
            XCTAssertEqual(after.entries[1].formatSpecific["flags"], "0x0800")
            for index in 2..<items.count {
                XCTAssertEqual(Int(after.records[index].recordRange.lowerBound), Int(before.records[index].recordRange.lowerBound) + delta)
            }
            XCTAssertEqual(after.bytes.count, before.bytes.count + 2 * delta)
            if label == "equal" {
                // 同長改名の全書庫 oracle: local / central の名前領域以外は一切変化しない。
                var patched = before.bytes
                patched.replaceSubrange((local + 30)..<(local + 30 + nfc.utf8.count), with: nfc.utf8)
                let old = ZipBytes(data: before.bytes)
                let central = old.central + 46 + Int(old.u16(old.central + 28)) + Int(old.u16(old.central + 30))
                patched.replaceSubrange((central + 46)..<(central + 46 + nfc.utf8.count), with: nfc.utf8)
                XCTAssertEqual(after.bytes, patched)
            }
            try assertCarried(before, to: url, indices: Array(items.indices), renamed: [1])
            var expected = items
            expected[1].name = nfc
            try ZipTestSupport.verify(url, expected: expected)
        }
    }

    func testDeleteRenameAndAppendShareOneAtomicCommitInEitherOrder() throws {
        for appendFirst in [true, false] {
            let (url, items) = try original("delete-rename-append-\(appendFirst)")
            let before = try Snapshot(url)
            let updater = try ArchiveUpdater.open(url: url)
            let added = ZipTestSupport.Expected(name: "added.txt", data: Data("追加\n".utf8))
            if appendFirst { try updater.add(data: added.data, as: added.name, modificationDate: added.date) }
            try updater.remove(entriesAt: [0, 3])
            try updater.rename(entryAt: 2, to: "temporary.txt")
            try updater.rename(entryAt: 2, to: "改名.txt")
            if !appendFirst { try updater.add(data: added.data, as: added.name, modificationDate: added.date) }
            // 予約した削除で空く名前を、同一 commit の追加で再利用できる。
            try updater.add(data: added.data, as: items[0].name, modificationDate: added.date)
            XCTAssertEqual(try Data(contentsOf: url), before.bytes)
            try updater.commit()
            try updater.commit()
            XCTAssertThrowsError(try updater.remove(entriesAt: [1]))
            XCTAssertThrowsError(try updater.rename(entryAt: 1, to: "late"))
            try assertCarried(before, to: url, indices: [1, 2, 4], renamed: [2])
            var expected = [items[1], items[2], items[4], added, added]
            expected[1].name = "改名.txt"
            expected[4].name = items[0].name
            try ZipTestSupport.verify(url, expected: expected)
        }
    }

    func testDittoDescriptorsSurviveNeighborDeletionAndRename() throws {
        let directory = try ZipTestSupport.directory("delete-ditto-descriptors")
        let source = directory.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for name in ["a.txt", "b.txt", "c.txt"] {
            let url = source.appendingPathComponent(name)
            try Data(String(repeating: "ditto: \(name)\n", count: 73).utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o640], ofItemAtPath: url.path)
        }
        let url = directory.appendingPathComponent("archive.zip")
        try ZipTestSupport.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", source.path, url.path], in: directory, log: "ditto-create")
        let before = try Snapshot(url)
        XCTAssertEqual(before.entries.count, 3)
        XCTAssertTrue(before.records.allSatisfy { $0.formatSpecific["hasDataDescriptor"] == "true" })
        XCTAssertTrue(before.records.allSatisfy { $0.recordRange.upperBound > $0.payloadRange.upperBound })
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: [1])
        try updater.rename(entryAt: 2, to: "longer-ditto-name.txt")
        try updater.commit()
        try assertCarried(before, to: url, indices: [0, 2], renamed: [2])
        let reader = try ArchiveReader.open(url: source.deletingLastPathComponent().appendingPathComponent("archive.zip"))
        let expected = try [0, 2].enumerated().map { offset, index in
            ZipTestSupport.Expected(name: offset == 0 ? before.entries[index].name : "longer-ditto-name.txt",
                data: try Data(contentsOf: source.appendingPathComponent(before.entries[index].name)), permissions: 0o640, date: date)
        }
        XCTAssertEqual(reader.entries.count, 2)
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testCP932DeletionKeepsEverySurvivingNameByte() throws {
        let directory = try ZipTestSupport.directory("delete-cp932")
        let url = directory.appendingPathComponent("archive.zip")
        // 公開 ZIP 表のクリーンルーム fixture。名前だけを CP932 で符号化する。
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        records=b''; cd=b''
        for text in ['削除.txt','日本語.txt','保存.txt']:
            name=text.encode('cp932'); data=b'CP932 payload\n'; crc=zlib.crc32(data)
            ts=p('HHBI',0x5455,5,1,1700000001)
            local=p('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(ts))+name+ts+data
            cd+=p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(ts),0,0,0,0o100644<<16,len(records))+name+ts
            records+=local
        open(sys.argv[1],'wb').write(records+cd+p('IHHHHIIH',0x06054b50,0,0,3,3,len(cd),len(records),0))
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-create")
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["l", "-slt", "-mcp=932", url.path], in: directory, log: "original-7zz-l")
        let before = try Snapshot(url)
        XCTAssertEqual(before.entries.map(\.name), ["削除.txt", "日本語.txt", "保存.txt"])
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: [0])
        try updater.commit()
        try assertCarried(before, to: url, indices: [1, 2])
        try ZipTestSupport.verify(url, expected: ["日本語.txt", "保存.txt"].map {
            .init(name: $0, data: Data("CP932 payload\n".utf8))
        }, legacyCP932: true, legacyOriginalIndices: [1, 2])
    }

    func testRemovingAllEntriesMatchesPythonEmptyZIP() throws {
        let (url, items) = try original("delete-all")
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: Array(items.indices))
        try updater.commit()
        XCTAssertEqual(try Data(contentsOf: url).count, 22)
        let directory = url.deletingLastPathComponent()
        let oracle = directory.appendingPathComponent("python-empty.zip")
        try ZipTestSupport.run("/usr/bin/python3", ["-c", "import sys,zipfile; zipfile.ZipFile(sys.argv[1],'w').close()", oracle.path], in: directory, log: "python-create")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: oracle))
        try ZipTestSupport.verify(url, expected: [])
    }

    func testInvalidIndicesAndUnsafeOrCollidingRenamesLeaveOriginalUntouched() throws {
        let (url, _) = try original("delete-rename-validation")
        let before = try Data(contentsOf: url)
        for index in [-1, 5, Int.max] {
            let updater = try ArchiveUpdater.open(url: url)
            XCTAssertThrowsError(try updater.remove(entriesAt: [0, index])) {
                XCTAssertEqual($0 as? UpdaterError, .invalidEntryIndex(index))
            }
            XCTAssertThrowsError(try updater.commit())
            let rename = try ArchiveUpdater.open(url: url)
            XCTAssertThrowsError(try rename.rename(entryAt: index, to: "safe")) {
                XCTAssertEqual($0 as? UpdaterError, .invalidEntryIndex(index))
            }
        }
        for name in ["", "../escape", "a/../../escape", "/absolute", "a\0b", "C:/absolute", "\\absolute",
                     "a//b", "./name", "entry-1.txt", "entry-1.txt/child", String(repeating: "a", count: 65_536)] {
            let updater = try ArchiveUpdater.open(url: url)
            XCTAssertThrowsError(try updater.rename(entryAt: 0, to: name))
            XCTAssertThrowsError(try updater.commit())
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        let removed = try ArchiveUpdater.open(url: url)
        try removed.remove(entriesAt: [0])
        XCTAssertThrowsError(try removed.rename(entryAt: 0, to: "deleted"))
        let collision = try ArchiveUpdater.open(url: url)
        try collision.add(data: Data(), as: "ガラス")
        XCTAssertThrowsError(try collision.rename(entryAt: 0, to: "カ\u{3099}ラス"))
        let pending = try ArchiveUpdater.open(url: url)
        try pending.rename(entryAt: 0, to: "reserved/child")
        XCTAssertThrowsError(try pending.rename(entryAt: 1, to: "reserved"))
        let added = try ArchiveUpdater.open(url: url)
        try added.rename(entryAt: 0, to: "reserved")
        XCTAssertThrowsError(try added.add(data: Data(), as: "reserved"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNilRawRecordRefusesOnlySurvivingEntries() throws {
        let (url, items) = try original("delete-nil-record")
        let before = try Snapshot(url)
        // 正常 ZIP は nil を返さない。実際の recovery entry の nil を取得境界へ注入する。
        let partial = Data(before.bytes.prefix(Int(before.records[0].payloadRange.upperBound) - 3))
        let incomplete = try ArchiveReader.open(data: partial, options: ReaderOptions(recoverDamagedArchives: true))
        let entry = try XCTUnwrap(incomplete.entries.first)
        XCTAssertTrue(entry.isIncomplete)
        XCTAssertNil(try incomplete.rawRecord(of: entry))
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: [4])
        var called: [Int] = []
        updater.rawRecord = { reader, original in
            called.append(original.index)
            if original.index == 1 { return try incomplete.rawRecord(of: entry) }
            return try reader.rawRecord(of: original)
        }
        XCTAssertThrowsError(try updater.commit()) { error in
            guard case let UpdaterError.nonRelocatableEntry(index, name, reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(index, 1)
            XCTAssertEqual(name, items[1].name)
            XCTAssertTrue(reason.contains("rawRecord が nil"))
            ZipTestSupport.report("REFUSAL \(reason)")
        }
        XCTAssertEqual(called, [0, 1])
        XCTAssertEqual(try Data(contentsOf: url), before.bytes)
        XCTAssertThrowsError(try updater.commit())
        let removing = try ArchiveUpdater.open(url: url)
        try removing.remove(entriesAt: [1])
        removing.rawRecord = { reader, original in
            XCTAssertNotEqual(original.index, 1)
            return try reader.rawRecord(of: original)
        }
        try removing.commit()
        try ZipTestSupport.verify(url, expected: [0, 2, 3, 4].map { items[$0] })
    }

    func testFailureAndAbandonmentAfterPartialWorkPreserveOriginal() throws {
        let (url, _) = try original("delete-rename-failure")
        let before = try Data(contentsOf: url)
        do {
            let updater = try ArchiveUpdater.open(url: url)
            try updater.remove(entriesAt: [1])
            try updater.rename(entryAt: 2, to: "queued")
            try updater.add(data: Data("queued bytes".utf8), as: "added")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        for failure in [WriterError.io(operation: "injected raw read", code: EIO), .sizeOverflow] {
            let updater = try ArchiveUpdater.open(url: url)
            try updater.remove(entriesAt: [4])
            var copied = 0
            updater.rawRecord = { reader, entry in
                if entry.index == 2 { throw failure }
                copied += 1
                return try reader.rawRecord(of: entry)
            }
            XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? WriterError, failure) }
            XCTAssertEqual(copied, 2)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testTaskCancellationDuringRebuildPreservesOriginal() async throws {
        let (url, _) = try original("delete-rename-cancel")
        let before = try Data(contentsOf: url)
        let task = Task {
            let updater = try ArchiveUpdater.open(url: url)
            try updater.remove(entriesAt: [4])
            updater.rawRecord = { reader, entry in
                if entry.index == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return try reader.rawRecord(of: entry)
            }
            try updater.commit()
        }
        do { try await task.value; XCTFail("cancelled rebuild succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testRebuildPreservesArchiveModeQuarantineXattrsCreationDateAndComment() throws {
        let (url, items) = try original("delete-rename-metadata")
        let comment = Data("Archive comment: 保持\n".utf8)
        var bytes = try Data(contentsOf: url)
        bytes.zipSet(UInt16(comment.count), at: bytes.count - 2)
        bytes.append(comment)
        try bytes.write(to: url)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o651], ofItemAtPath: url.path)
        let tag = try PropertyListSerialization.data(fromPropertyList: ["凝縮\n2"], format: .binary, options: 0)
        let values = [("com.apple.quarantine", Data("0081;6553f101;GyoshukuKit;01234567-89AB-CDEF-0123-456789ABCDEF".utf8)),
                      ("com.example.GyoshukuKit", Data("metadata".utf8)), ("com.apple.metadata:_kMDItemUserTags", tag)]
        for (name, data) in values {
            XCTAssertEqual(data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }, 0)
        }
        let creation = try manager.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: [0, 4])
        try updater.rename(entryAt: 2, to: "metadata-renamed.txt")
        try updater.commit()
        XCTAssertEqual(try Data(contentsOf: url).suffix(comment.count), comment)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o651)
        XCTAssertEqual(attributes[.creationDate] as? Date, creation)
        for (name, data) in values {
            var value = Data(count: data.count)
            XCTAssertEqual(value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }, data.count)
            XCTAssertEqual(value, data)
        }
        var expected = [items[1], items[2], items[3]]
        expected[1].name = "metadata-renamed.txt"
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testFolderRenamesAreExplicitAndPreserveSymlinks() throws {
        let directory = try ZipTestSupport.directory("rename-folder")
        let input = directory.appendingPathComponent("input")
        let sub = input.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("contents\n".utf8).write(to: sub.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: input.appendingPathComponent("link").path, withDestinationPath: "sub/file.txt")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(contentsOf: input, as: "folder")
        try writer.finish()
        let before = try Snapshot(url)
        let reader = try ArchiveReader.open(url: url)
        var expected = try reader.entries.map {
            ZipTestSupport.Expected(name: $0.name, data: try reader.read($0), kind: $0.kind,
                permissions: try XCTUnwrap($0.posixPermissions), date: try XCTUnwrap($0.modificationDate))
        }
        let updater = try ArchiveUpdater.open(url: url)
        // directory だけの改名では子孫は動かない。各 index を呼出側が明示的に予約する。
        try updater.rename(entryAt: 0, to: "renamed")
        try updater.commit()
        expected[0].name = "renamed/"
        try assertCarried(before, to: url, indices: Array(before.entries.indices), renamed: [0])
        try ZipTestSupport.verify(url, expected: expected)

        let movedDirectory = try ZipTestSupport.directory("rename-folder-descendants")
        let moved = movedDirectory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: url, to: moved)
        let descendants = try ArchiveUpdater.open(url: moved)
        for index in 1..<expected.count {
            expected[index].name = "renamed" + expected[index].name.dropFirst("folder".count)
            try descendants.rename(entryAt: index, to: expected[index].name)
        }
        try descendants.commit()
        try ZipTestSupport.verify(moved, expected: expected)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: movedDirectory.appendingPathComponent("ditto/renamed/link").path)
        XCTAssertEqual(target, "sub/file.txt")
    }

    func testCP932RenameInvalidatesUnicodePathExtraWithoutMovingEqualLengthPayload() throws {
        let directory = try ZipTestSupport.directory("rename-cp932-unicode-extra")
        let url = directory.appendingPathComponent("archive.zip")
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        name='日本語.txt'.encode('cp932'); data=b'legacy contents\n'; crc=zlib.crc32(data)
        unicode='日本語.txt'.encode('utf8'); body=p('BI',1,zlib.crc32(name))+unicode
        unicode_extra=p('HH',0x7075,len(body))+body
        local_ts=p('HHBII',0x5455,9,3,1700000001,1700000000)
        central_ts=p('HHBI',0x5455,5,1,1700000001)
        unknown=p('HH',0xcafe,3)+b'xyz'; lx=local_ts+unicode_extra+unknown; cx=central_ts+unicode_extra+unknown
        comment=b'entry comment retained'
        local=p('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(lx))+name+lx+data
        cd=p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(cx),len(comment),0,1,0o100751<<16,0)+name+cx+comment
        open(sys.argv[1],'wb').write(local+cd+p('IHHHHIIH',0x06054b50,0,0,1,1,len(cd),len(local),0))
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-create")
        let before = try Snapshot(url)
        let updater = try ArchiveUpdater.open(url: url)
        // CP932 の旧名 10 byte に対し UTF-8 の新名も 10 byte。
        try updater.rename(entryAt: 0, to: "変更.txt")
        try updater.commit()
        let after = try Snapshot(url)
        XCTAssertEqual(before.records[0].payloadRange, after.records[0].payloadRange)
        XCTAssertEqual(before.bytes.count, after.bytes.count)
        let bytes = ZipBytes(data: after.bytes), old = ZipBytes(data: before.bytes)
        XCTAssertEqual(bytes.u16(6), 0x0800)
        XCTAssertEqual(bytes.u16(bytes.central + 8), 0x0800)
        for local in [true, false] {
            let extras = bytes.extras(local ? 0 : bytes.central, local: local)
            XCTAssertNil(extras[0x7075])
            XCTAssertEqual(extras[0xcafe], Data("xyz".utf8))
            XCTAssertEqual(extras[0x5455], old.extras(local ? 0 : old.central, local: local)[0x5455])
        }
        XCTAssertEqual(bytes.u16(bytes.central + 36), 1)
        XCTAssertEqual(bytes.u16(bytes.central + 32), UInt16("entry comment retained".utf8.count))
        XCTAssertEqual(after.bytes.subdata(in: (bytes.end - "entry comment retained".utf8.count)..<bytes.end), Data("entry comment retained".utf8))
        try assertCarried(before, to: url, indices: [0], renamed: [0])
        try ZipTestSupport.verify(url, expected: [.init(name: "変更.txt", data: Data("legacy contents\n".utf8), permissions: 0o751)])
    }

    func testConcurrentReplacementRejectsQueuedRebuild() throws {
        let (url, items) = try original("delete-rename-source-changed")
        let loser = try ArchiveUpdater.open(url: url)
        try loser.remove(entriesAt: [0])
        try loser.rename(entryAt: 1, to: "loser")
        let winner = try ArchiveUpdater.open(url: url)
        try winner.remove(entriesAt: [4])
        try winner.commit()
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try loser.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try ZipTestSupport.verify(url, expected: Array(items.prefix(4)))
    }
}
