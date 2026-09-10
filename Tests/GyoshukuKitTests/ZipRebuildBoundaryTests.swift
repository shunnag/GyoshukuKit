import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipRebuildBoundaryTests: XCTestCase {
    func testZIP64CountDropsBelowLimitAndReturnsAfterMixedCommit() throws {
        let directory = try ZipTestSupport.directory("rebuild-zip64-count-down")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        var expected: [ZipTestSupport.Expected] = []
        for index in 0..<65_536 {
            let name = String(format: "entry-%05d", index)
            try writer.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
            expected.append(.init(name: name))
        }
        try writer.finish()
        let original = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(original.u32(original.end - 20), 0x07064B50)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.remove(entriesAt: [0, 1, 65_535])
        try updater.commit()
        expected = Array(expected[2..<65_535])
        let down = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(down.u16(down.end + 10), 65_533)
        XCTAssertNotEqual(down.u32(down.end - 20), 0x07064B50)
        XCTAssertEqual(down.end, down.central + Int(down.u32(down.end + 12)))
        try ZipTestSupport.verify(url, expected: expected)
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("unzip-l.log"), encoding: .utf8).contains("65533 files"))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("7zz-t.log"), encoding: .utf8).contains("Files: 65533"))
        ZipTestSupport.report("KAITO REBUILD ZIP64 down: count=65533, ZIP64 EOCD absent; every entry verified")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ditto"))

        let upDirectory = try ZipTestSupport.directory("rebuild-zip64-count-up")
        let upURL = upDirectory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: url, to: upURL)
        let again = try ArchiveUpdater.open(url: upURL)
        try again.rename(entryAt: 0, to: "renamed-00002")
        expected[0].name = "renamed-00002"
        for index in 0..<3 {
            let name = "added-\(index)"
            try again.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
            expected.append(.init(name: name))
        }
        try again.commit()
        let up = ZipBytes(data: try Data(contentsOf: upURL))
        XCTAssertEqual(up.u16(up.end + 10), UInt16.max)
        XCTAssertEqual(up.u32(up.end - 20), 0x07064B50)
        let end64 = Int(up.u64(up.end - 12))
        XCTAssertEqual(up.u32(end64), 0x06064B50)
        XCTAssertEqual(up.u64(end64 + 32), 65_536)
        XCTAssertNotEqual(up.u32(up.end + 12), UInt32.max)
        XCTAssertNotEqual(up.u32(up.end + 16), UInt32.max)
        try ZipTestSupport.verify(upURL, expected: expected)
        XCTAssertTrue(try String(contentsOf: upDirectory.appendingPathComponent("unzip-l.log"), encoding: .utf8).contains("65536 files"))
        XCTAssertTrue(try String(contentsOf: upDirectory.appendingPathComponent("7zz-t.log"), encoding: .utf8).contains("Files: 65536"))
        ZipTestSupport.report("KAITO REBUILD ZIP64 up: count=65536, ZIP64 EOCD present; every entry verified")
        try FileManager.default.removeItem(at: upDirectory.appendingPathComponent("ditto"))
    }

    func testRebuiltCentralDirectoryAddsAndDropsEachZIP64FieldIndependently() throws {
        let directory = try ZipTestSupport.directory("rebuild-zip64-fields")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(data: Data([1, 2, 3]), as: "x", modificationDate: ZipTestSupport.date)
        try writer.finish()
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let header = try ZipRebuild.CentralHeader(source: source, at: layout.centralOffset, end: layout.centralOffset + layout.centralSize)
        let limit = UInt64(UInt32.max)
        for (size, compressed, offset) in [(limit - 1, UInt64(17), UInt64(0)), (limit, 17, 0),
                                          (17, limit, 0), (17, 19, limit - 1), (17, 19, limit),
                                          (limit, limit, limit), (limit + 1, 19, limit + 1)] {
            let data = try header.rebuilt(offset: offset, size: size, compressedSize: compressed, name: nil)
            let bytes = ZipBytes(data: data)
            XCTAssertEqual(bytes.u32(24), UInt32(min(size, limit)))
            XCTAssertEqual(bytes.u32(20), UInt32(min(compressed, limit)))
            XCTAssertEqual(bytes.u32(42), UInt32(min(offset, limit)))
            let values = [size >= limit ? size : nil, compressed >= limit ? compressed : nil, offset >= limit ? offset : nil].compactMap { $0 }
            let extra = bytes.extras(0, local: false)[1]
            XCTAssertEqual(extra?.count ?? 0, 8 * values.count)
            if let extra {
                for (index, value) in values.enumerated() { XCTAssertEqual(ZipBytes(data: extra).u64(8 * index), value) }
            }
            // 旧 CD に ZIP64 がある場合も小さい新 offset / size では field 自体を落とす。
            let centralURL = directory.appendingPathComponent("central.bin")
            try data.write(to: centralURL)
            let large = try ZipRebuild.CentralHeader(source: ZipUpdateSource(url: centralURL), at: 0, end: UInt64(data.count))
            let small = ZipBytes(data: try large.rebuilt(offset: 0, size: 3, compressedSize: 5, name: nil))
            XCTAssertNil(small.extras(0, local: false)[1])
            XCTAssertEqual(small.u32(24), 3)
            XCTAssertEqual(small.u32(20), 5)
            XCTAssertEqual(small.u32(42), 0)
            XCTAssertEqual(small.extras(0, local: false)[0x5455], bytes.extras(0, local: false)[0x5455])
        }
        try ZipTestSupport.verify(url, expected: [.init(name: "x", data: Data([1, 2, 3]))])
    }

    func testSignedZIP32AndZIP64DescriptorsSurviveRebuild() throws {
        let directory = try ZipTestSupport.directory("rebuild-signed-descriptors")
        let url = directory.appendingPathComponent("archive.zip")
        // KaitoKit と独立した公開 byte 表の fixture。data descriptor の幅は検証側だけで作る。
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        records=b''; cd=b''
        for i,width in enumerate([0,16,24]):
            name=('entry-%d'%i).encode(); data=('descriptor %d\n'%width).encode()
            compressor=zlib.compressobj(wbits=-15); payload=compressor.compress(data)+compressor.flush()
            crc=zlib.crc32(data); flags=0x800|(8 if width else 0); wide=width>=20
            ts=p('HHBI',0x5455,5,1,1700000001)
            lx=(p('HHQQ',1,16,len(data),len(payload)) if wide else b'')+ts
            cx=(p('HHQQ',1,16,len(data),len(payload)) if wide else b'')+ts
            local=p('IHHHHHIIIHH',0x04034b50,45 if wide else 20,flags,8,0,0x21,0 if width else crc,
              0xffffffff if wide else (0 if width else len(payload)),
              0xffffffff if wide else (0 if width else len(data)),len(name),len(lx))+name+lx+payload
            if width:
                if width in [16,24]: local+=p('I',0x08074b50)
                local+=p('IQQ' if wide else 'III',crc,len(payload),len(data))
            cd+=p('IHHHHHHIIIHHHHHII',0x02014b50,0x032d,45 if wide else 20,flags,8,0,0x21,crc,
              0xffffffff if wide else len(payload),0xffffffff if wide else len(data),len(name),len(cx),0,0,0,0o100644<<16,len(records))+name+cx
            records+=local
        open(sys.argv[1],'wb').write(records+cd+p('IHHHHIIH',0x06054b50,0,0,3,3,len(cd),len(records),0))
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-create")
        let before = try Data(contentsOf: url)
        let reader = try ArchiveReader.open(url: url)
        let records = try reader.entries.map { try XCTUnwrap(reader.rawRecord(of: $0)) }
        XCTAssertEqual(records.map { Int($0.recordRange.upperBound - $0.payloadRange.upperBound) }, [0, 16, 24])
        let updater = try ArchiveUpdater.open(url: url)
        try updater.rename(entryAt: 0, to: "longer-first-name")
        try updater.commit()
        let after = try Data(contentsOf: url)
        let result = try ArchiveReader.open(url: url)
        for index in 1..<3 {
            let raw = try XCTUnwrap(result.rawRecord(of: result.entries[index]))
            XCTAssertEqual(after.subdata(in: Int(raw.recordRange.lowerBound)..<Int(raw.recordRange.upperBound)),
                           before.subdata(in: Int(records[index].recordRange.lowerBound)..<Int(records[index].recordRange.upperBound)))
        }
        let expected = [0, 16, 24].enumerated().map { index, width in
            ZipTestSupport.Expected(name: index == 0 ? "longer-first-name" : "entry-\(index)", data: Data("descriptor \(width)\n".utf8))
        }
        try ZipTestSupport.verify(url, expected: expected)
    }

    func testZIP32DescriptorCrossingZIP64OffsetIsRefusedWithoutChangingOriginal() throws {
        let directory = try ZipTestSupport.directory("rebuild-zip64-descriptor-refusal")
        let url = directory.appendingPathComponent("archive.zip")
        try makeOffsetFixture(url, descriptor: true)
        let backup = directory.appendingPathComponent("original.zip")
        try FileManager.default.copyItem(at: url, to: backup)
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max)))
        let raw = try XCTUnwrap(reader.rawRecord(of: reader.entries[1]))
        XCTAssertEqual(raw.formatSpecific["hasDataDescriptor"], "true")
        XCTAssertEqual(raw.formatSpecific["isZIP64"], "false")
        XCTAssertLessThan(raw.recordRange.lowerBound, UInt64(UInt32.max))
        // offset 用 ZIP64 extra だけを足した小さい対照入力でも、KaitoKit が descriptor を
        // wide と解釈することを実 API で確認する。payload の通常読取は成功する。
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let first = try ZipRebuild.CentralHeader(source: source, at: layout.centralOffset,
            end: layout.centralOffset + layout.centralSize)
        let tailHeader = try ZipRebuild.CentralHeader(source: source,
            at: layout.centralOffset + UInt64(first.byteCount), end: layout.centralOffset + layout.centralSize)
        var central = try tailHeader.rebuilt(offset: UInt64(UInt32.max), size: 19, compressedSize: 19, name: nil)
        // sentinel と offset 専用 extra の形を保ったまま、対照入力内の実 offset 0 にする。
        central.zipSet(UInt64(0), at: 46 + Int(central.zip16(28)) + 4)
        var control = try source.bytes(at: raw.recordRange.lowerBound, count: Int(raw.recordRange.count))
        let centralOffset = UInt64(control.count)
        control.append(central)
        control.append(try ZipRecords.end(count: 1, centralSize: UInt64(central.count), centralOffset: centralOffset))
        let controlReader = try ArchiveReader.open(data: control)
        XCTAssertEqual(try controlReader.read(controlReader.entries[0]), Data("after the boundary\n".utf8))
        XCTAssertThrowsError(try controlReader.rawRecord(of: controlReader.entries[0])) { error in
            guard case let KaitoError.malformed(reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, "ZIP data descriptor overlaps the next record or central directory")
            ZipTestSupport.report("KAITO OFFSET DESCRIPTOR LIMIT: \(reason)")
        }
        let updater = try ArchiveUpdater.open(url: url)
        try updater.rename(entryAt: 0, to: "longer-first-name")
        XCTAssertThrowsError(try updater.commit()) { error in
            guard case let UpdaterError.nonRelocatableEntry(index, name, reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(index, 1)
            XCTAssertEqual(name, "tail.txt")
            XCTAssertTrue(reason.contains("KaitoKit 0.4.0"))
            ZipTestSupport.report("REFUSAL \(reason)")
        }
        try ZipTestSupport.run("/usr/bin/cmp", [url.path, backup.path], in: directory, log: "original-cmp")
        XCTAssertThrowsError(try updater.commit())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: backup)
    }

    private func makeOffsetFixture(_ url: URL, descriptor: Bool = false) throws {
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        ts=p('HHBI',0x5455,5,1,1700000001); offset=0xffffffff-4
        size=offset-30-1-len(ts); crc=0; remaining=size; zeros=b'\0'*(1024*1024)
        while remaining:
            n=min(remaining,len(zeros)); crc=zlib.crc32(zeros[:n],crc); remaining-=n
        tail=b'after the boundary\n'; tailcrc=zlib.crc32(tail); descriptor=sys.argv[2]=='true'
        def local(name,data_size,crc,dd=False):
            return p('IHHHHHIIIHH',0x04034b50,20,0x808 if dd else 0x800,0,0,0x21,0 if dd else crc,0 if dd else data_size,0 if dd else data_size,len(name),len(ts))+name+ts
        def central(name,data_size,crc,off,mode,dd=False):
            return p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0x808 if dd else 0x800,0,0,0x21,crc,data_size,data_size,len(name),len(ts),0,0,0,mode<<16,off)+name+ts
        with open(sys.argv[1],'wb') as f:
            f.write(local(b'x',size,crc)); f.seek(offset); f.write(local(b'tail.txt',len(tail),tailcrc,descriptor)+tail)
            if descriptor: f.write(p('IIII',0x08074b50,tailcrc,len(tail),len(tail)))
            cd_offset=f.tell(); cd=central(b'x',size,crc,0,0o100640)+central(b'tail.txt',len(tail),tailcrc,offset,0o100755,descriptor)
            f.write(cd); end64=f.tell()
            f.write(p('IQHHIIQQQQ',0x06064b50,44,0x032d,45,0,0,2,2,len(cd),cd_offset))
            f.write(p('IIQI',0x07064b50,0,end64,1))
            f.write(p('IHHHHIIH',0x06054b50,0,0,2,2,len(cd),0xffffffff,0))
        print('sparse fixture: tail offset=%d, stored payload=%d, CRC=%08x'%(offset,size,crc))
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path, String(descriptor)], in: url.deletingLastPathComponent(), log: "python-create")
    }

    func testLocalOffsetCrosses4GiBThenDropsAfterDeletion() throws {
        let directory = try ZipTestSupport.directory("rebuild-zip64-offset-up")
        let url = directory.appendingPathComponent("archive.zip")
        // 大きい stored payload の入力だけ sparse で作る。updater は穴を特別扱いせず全 byte を運ぶ。
        // 末尾 entry の offset が 0xFFFFFFFF の直前から、先頭の改名で境界を越える。
        try makeOffsetFixture(url)
        let limits = ReadLimits(maxEntrySize: UInt64.max, maxTotalUncompressedSize: UInt64.max)
        let before = try ArchiveReader.open(url: url, options: ReaderOptions(limits: limits))
        let first = before.entries[0], tail = before.entries[1]
        let oldTail = try XCTUnwrap(before.rawRecord(of: tail))
        XCTAssertEqual(oldTail.recordRange.lowerBound, UInt64(UInt32.max) - 4)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.rename(entryAt: 0, to: "longer-first-name")
        try updater.commit()
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let firstCentral = try source.bytes(at: layout.centralOffset, count: 46)
        let tailCentralOffset = layout.centralOffset + 46 + UInt64(firstCentral.zip16(28)) + UInt64(firstCentral.zip16(30))
        let tailCentral = try source.bytes(at: tailCentralOffset, count: 46)
        XCTAssertEqual(tailCentral.zip32(42), UInt32.max)
        let extras = try source.bytes(at: tailCentralOffset + 46 + UInt64(tailCentral.zip16(28)), count: Int(tailCentral.zip16(30)))
        XCTAssertEqual(extras.zip16(0), 1)
        XCTAssertEqual(extras.zip16(2), 8)
        XCTAssertEqual(extras.zip64(4), oldTail.recordRange.lowerBound + UInt64("longer-first-name".utf8.count - 1))
        XCTAssertGreaterThanOrEqual(layout.centralOffset, UInt64(UInt32.max))
        let result = try ArchiveReader.open(url: url, options: ReaderOptions(limits: limits))
        XCTAssertEqual(result.entries.map(\.name), ["longer-first-name", "tail.txt"])
        for (entry, original) in zip(result.entries, [first, tail]) {
            XCTAssertEqual(entry.modificationDate, original.modificationDate)
            XCTAssertEqual(entry.posixPermissions, original.posixPermissions)
            XCTAssertEqual(entry.crc32, original.crc32)
            XCTAssertEqual(entry.compressedSize, original.compressedSize)
            XCTAssertEqual(entry.uncompressedSize, original.uncompressedSize)
        }
        let rawTail = try XCTUnwrap(result.rawRecord(of: result.entries[1]))
        let oldSource = try before.read(tail)
        XCTAssertEqual(try result.read(result.entries[1]), oldSource)
        XCTAssertEqual(rawTail.recordRange.lowerBound, extras.zip64(4))
        XCTAssertTrue(try ZipTestSupport.run("/usr/bin/unzip", ["-t", url.path], in: directory, log: "unzip-t").contains("No errors detected"))
        try ZipTestSupport.run("/usr/bin/unzip", ["-l", url.path], in: directory, log: "unzip-l")
        XCTAssertTrue(try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", url.path], in: directory, log: "7zz-t").contains("Everything is Ok"))
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["l", "-slt", url.path], in: directory, log: "7zz-l")
        let extracted = directory.appendingPathComponent("ditto")
        try ZipTestSupport.run("/usr/bin/ditto", ["-x", "-k", url.path, extracted.path], in: directory, log: "ditto-x")
        try ZipTestSupport.run("/usr/bin/tar", ["-tf", url.path], in: directory, log: "bsdtar-t")
        let stream = try result.stream(result.entries[0])
        let disk = try FileHandle(forReadingFrom: extracted.appendingPathComponent("longer-first-name"))
        defer { try? disk.close() }
        let zeros = Data(repeating: 0, count: 256 * 1024)
        var buffer = Data(count: zeros.count), crc = CRC32(), total: UInt64 = 0
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            XCTAssertEqual(buffer.prefix(count), zeros.prefix(count))
            XCTAssertEqual(try disk.read(upToCount: count), buffer.prefix(count))
            crc.update(buffer.prefix(count))
            total += UInt64(count)
        }
        XCTAssertTrue((try disk.read(upToCount: 1) ?? Data()).isEmpty)
        XCTAssertEqual(total, first.uncompressedSize)
        XCTAssertEqual(crc.value, first.crc32)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("tail.txt")), oldSource)
        ZipTestSupport.report("KAITO REBUILD offset up: \(rawTail.recordRange.lowerBound), size=\(total), CRC=\(String(crc.value, radix: 16)); every payload byte and ditto output verified")
        try FileManager.default.removeItem(at: extracted)

        let downDirectory = try ZipTestSupport.directory("rebuild-zip64-offset-down")
        let downURL = downDirectory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: url, to: downURL)
        let deleting = try ArchiveUpdater.open(url: downURL)
        try deleting.remove(entriesAt: [0])
        try deleting.commit()
        let down = ZipBytes(data: try Data(contentsOf: downURL))
        XCTAssertEqual(down.u32(down.central + 42), 0)
        XCTAssertNil(down.extras(down.central, local: false)[1])
        XCTAssertNotEqual(down.u32(down.end - 20), 0x07064B50)
        try ZipTestSupport.verify(downURL, expected: [.init(name: "tail.txt", data: oldSource, permissions: 0o755)])
        ZipTestSupport.report("KAITO REBUILD offset down: 0, ZIP64 field and EOCD absent")
        // 検証ログと小さい最終書庫を残し、4 GiB の作業書庫は残さない。
        try FileManager.default.removeItem(at: url)
    }
}
