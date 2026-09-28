import Foundation
import Darwin
import XCTest
@_spi(ZipRawLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class ZipReencryptionBoundaryTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let directory = try ZipTestSupport.directory("reencrypt-boundary-" + name)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testDescriptorsZIP64ExtrasReorderedRecordsAndMetadata() throws {
        let directory = try directory("headers")
        let source = directory.appendingPathComponent("source.zip")
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        field=lambda i,b:p('HH',i,len(b))+b
        records=b''; entries=[]
        for i,width in enumerate([12,16,20,24,0,20]):
            name=('entry-%d'%i).encode(); data=('payload-%d'%i).encode()*5
            c=zlib.compressobj(wbits=-15); payload=c.compress(data)+c.flush(); crc=zlib.crc32(data)
            wide=width>=20 or i==4; localwide=wide and i!=5
            extra=field(0xcafe,b'opaque')+field(0x5455,p('BII',3,1700000001,1600000001))+field(0x7875,b'\x01\x04\x01\0\0\0\x04\x02\0\0\0')
            lx=extra+(field(1,p('QQ',len(data),len(payload))) if localwide else b'')+b'\0\0'
            cx=extra+(field(1,p('QQ',len(data),len(payload))) if wide else b'')+b'\xaa\xbb'
            flags=0x806|(8 if width else 0); version=45 if wide else 20
            local=p('IHHHHHIIIHH',0x04034b50,0x300|version,flags,8,0x1234,0x5678,0 if width else crc,
                0xffffffff if localwide else (0 if width else len(payload)),0xffffffff if localwide else (0 if width else len(data)),len(name),len(lx))+name+lx+payload
            if width:
                if width in [16,24]:local+=p('I',0x08074b50)
                local+=p('IQQ' if wide else 'III',crc,len(payload),len(data))
            comment=('comment-%d'%i).encode()
            cd=p('IHHHHHHIIIHHHHHII',0x02014b50,0x33f,0x300|version,flags,8,0x1234,0x5678,crc,
                0xffffffff if wide else len(payload),0xffffffff if wide else len(data),len(name),len(cx),len(comment),0,3,0o100751<<16,len(records))+name+cx+comment
            entries.append(cd);records+=local+b'gap-between-records'
        cd=b''.join(entries[i] for i in [2,0,5,1,4,3]);comment=b'archive-comment'
        open(sys.argv[1],'wb').write(records+cd+p('IHHHHIIH',0x06054b50,0,0,6,6,len(cd),len(records),len(comment))+comment)
        """#
        try ZipTestSupport.run(ReferenceTool.python3, ["-c", script, source.path], in: directory, log: "create")
        let input = try ReencryptionSupport.reader(source)
        let oldSource = try ZipUpdateSource(url: source), oldLayout = try ZipUpdateLayout(source: oldSource)
        let oldDirectory = try ZipCentralDirectory.validate(source: oldSource, reader: input, centralOffset: oldLayout.centralOffset, centralSize: oldLayout.centralSize)
        for encryption in [ZipEncryption.aes256, .zipCrypto] {
            let output = directory.appendingPathComponent("\(encryption).zip")
            try ReencryptionSupport.convert(source, to: output, current: nil, password: "new", encryption: encryption)
            try ReencryptionSupport.assertStoredEqual(source, output, current: nil, password: "new")
            let reader = try ReencryptionSupport.reader(output, password: "new")
            XCTAssertEqual(reader.entries.map(\.name), input.entries.map(\.name))
            let resultSource = try ZipUpdateSource(url: output), resultLayout = try ZipUpdateLayout(source: resultSource)
            XCTAssertEqual(resultLayout.comment, oldLayout.comment)
            let resultDirectory = try ZipCentralDirectory.validate(source: resultSource, reader: reader, centralOffset: resultLayout.centralOffset, centralSize: resultLayout.centralSize)
            var position: UInt64 = 0
            for index in reader.entries.indices {
                let raw = resultDirectory.records[index].layout
                XCTAssertEqual(raw.recordRange.lowerBound, position)
                position = raw.recordRange.upperBound
                XCTAssertFalse(raw.hasDataDescriptor); XCTAssertFalse(raw.isZIP64)
                let local = try ZipRebuild.LocalHeader(source: resultSource, layout: raw)
                let cd = try ZipRebuild.CentralHeader(bytes: resultDirectory.bytes, range: resultDirectory.records[index].centralRange)
                let old = try ZipRebuild.CentralHeader(bytes: oldDirectory.bytes, range: oldDirectory.records[index].centralRange)
                XCTAssertEqual(local.fixed.zip16(6) & 9, 1)
                XCTAssertEqual(local.fixed.zip16(6), cd.fixed.zip16(8))
                XCTAssertEqual(local.fixed.zip16(8), encryption == .aes256 ? 99 : 8)
                XCTAssertEqual(local.fixed.zip16(4) & 0xff00, 0x300)
                XCTAssertEqual(cd.fixed.zip16(6) & 0xff00, 0x300)
                XCTAssertEqual(local.fixed.zip32(14), cd.fixed.zip32(16))
                XCTAssertEqual(UInt64(local.fixed.zip32(18)), reader.entries[index].compressedSize)
                XCTAssertEqual(UInt64(local.fixed.zip32(22)), reader.entries[index].uncompressedSize)
                XCTAssertEqual(cd.name, old.name); XCTAssertEqual(cd.comment, old.comment)
                for range in [4..<6, 12..<16, 36..<42] { XCTAssertEqual(cd.fixed.subdata(in: range), old.fixed.subdata(in: range)) }
                let oldFields = ZipRebuild.extraFields(old.extra).filter { $0.id != 1 }.map { old.extra.subdata(in: $0.range) }
                let fields = ZipRebuild.extraFields(cd.extra).filter { $0.id != 0x9901 }.map { cd.extra.subdata(in: $0.range) }
                XCTAssertEqual(fields, oldFields)
                XCTAssertEqual(cd.extra.suffix(2), old.extra.suffix(2))
                if encryption == .aes256 {
                    let lx = try XCTUnwrap(ZipRebuild.extraFields(local.extra).last)
                    let cx = try XCTUnwrap(ZipRebuild.extraFields(cd.extra).last)
                    XCTAssertEqual(lx.id, 0x9901); XCTAssertEqual(cx.id, 0x9901)
                    XCTAssertEqual(local.extra.subdata(in: lx.range), Data([1, 0x99, 7, 0, 2, 0, 65, 69, 3, 8, 0]))
                    XCTAssertEqual(local.extra.subdata(in: lx.range), cd.extra.subdata(in: cx.range))
                }
            }
        }
    }

    func testExtraFieldLengthLimitAndRenamePrivacy() throws {
        let directory = try directory("extra-limit")
        for length in [65_524, 65_525] {
            let source = directory.appendingPathComponent("\(length).zip")
            let script = #"""
            import struct,zlib,sys
            p=lambda f,*v:struct.pack('<'+f,*v)
            n=int(sys.argv[2]);name=b'x';data=b'a';crc=zlib.crc32(data);extra=p('HH',0xcafe,n-4)+b'\0'*(n-4)
            local=p('IHHHHHIIIHH',0x04034b50,20,0x800,0,0,0x21,crc,1,1,1,n)+name+extra+data
            cd=p('IHHHHHHIIIHHHHHII',0x02014b50,0x314,20,0x800,0,0,0x21,crc,1,1,1,n,0,0,0,0o100644<<16,0)+name+extra
            open(sys.argv[1],'wb').write(local+cd+p('IHHHHIIH',0x06054b50,0,0,1,1,len(cd),len(local),0))
            """#
            try ZipTestSupport.run(ReferenceTool.python3, ["-c", script, source.path, String(length)], in: directory, log: "create-\(length)")
            if length == 65_525 { try ReencryptionSupport.assertFailure(source, password: "new", current: nil) }
            else {
                let output = directory.appendingPathComponent("out.zip")
                try ReencryptionSupport.convert(source, to: output, current: nil, password: "new")
                try ReencryptionSupport.assertStoredEqual(source, output, current: nil, password: "new")
                let reader = try ReencryptionSupport.reader(output)
                let raw = ZipRecordLayout(try XCTUnwrap(reader.zipRawRecordLayout(at: 0)))
                XCTAssertEqual(try ZipRebuild.LocalHeader(source: ZipUpdateSource(url: output), layout: raw).extra.count, 65_535)
            }
        }
        let source = try ReencryptionSupport.fixture(directory, name: "rename.zip", items: [("old-name", Data([1]))])
        let output = directory.appendingPathComponent("renamed.zip")
        let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "new"))
        try updater.rename(entryAt: 0, to: "日本語")
        try updater.reencryptExistingEntries(currentPassword: nil)
        try updater.commit()
        XCTAssertEqual(try ReencryptionSupport.reader(output).entries[0].name, "日本語")
        XCTAssertNil(try Data(contentsOf: output).range(of: Data("old-name".utf8)))
    }

    func testConversionAndRenameNeutralizeUnicodePathExtra() throws {
        let directory = try directory("unicode-extra"), source = directory.appendingPathComponent("source.zip")
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        name=b'old-private-name';data=b'payload';crc=zlib.crc32(data)
        body=b'\x01'+p('I',zlib.crc32(name))+name;extra=p('HH',0x7075,len(body))+body
        local=p('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(extra))+name+extra+data
        cd=p('IHHHHHHIIIHHHHHII',0x02014b50,0x314,20,0,0,0,0x21,crc,len(data),len(data),len(name),len(extra),0,0,0,0o100644<<16,0)+name+extra
        open(sys.argv[1],'wb').write(local+cd+p('IHHHHIIH',0x06054b50,0,0,1,1,len(cd),len(local),0))
        """#
        try ZipTestSupport.run(ReferenceTool.python3, ["-c", script, source.path], in: directory, log: "create")
        let updater = try ArchiveUpdater.open(url: source, options: .init(password: "new"))
        try updater.rename(entryAt: 0, to: "新しい名前")
        try updater.reencryptExistingEntries(currentPassword: nil)
        try updater.commit()
        let bytes = try Data(contentsOf: source)
        XCTAssertNil(bytes.range(of: Data("old-private-name".utf8)))
        let reader = try ReencryptionSupport.reader(source, password: "new"), input = try ZipUpdateSource(url: source)
        XCTAssertEqual(reader.entries[0].name, "新しい名前")
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload".utf8))
        let layout = try ZipUpdateLayout(source: input)
        let raw = ZipRecordLayout(try XCTUnwrap(reader.zipRawRecordLayout(at: 0)))
        let local = try ZipRebuild.LocalHeader(source: input, layout: raw)
        let cd = try ZipRebuild.CentralHeader(source: input, at: layout.centralOffset, end: layout.centralOffset + layout.centralSize)
        for extra in [local.extra, cd.extra] {
            let fields = ZipRebuild.extraFields(extra)
            XCTAssertFalse(fields.contains { $0.id == 0x7075 })
            let padding = try XCTUnwrap(fields.first { $0.id == 0xffff })
            XCTAssertTrue(extra[(padding.range.lowerBound + 4)..<padding.range.upperBound].allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(local.fixed.zip16(6) & 0x800, 0x800)
        XCTAssertEqual(cd.fixed.zip16(8) & 0x800, 0x800)
    }

    private func setMethod(_ method: UInt16, in url: URL) throws {
        let reader = try ReencryptionSupport.reader(url), source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
        var bytes = try Data(contentsOf: url)
        if case .winZipAES = raw.encryption {
            for (offset, fixed, nameOffset, extraOffset) in [(Int(raw.recordRange.lowerBound), 30, 26, 28), (Int(layout.centralOffset), 46, 28, 30)] {
                let start = offset + fixed + Int(bytes.zip16(offset + nameOffset))
                let extra = bytes.subdata(in: start..<(start + Int(bytes.zip16(offset + extraOffset))))
                let field = try XCTUnwrap(ZipRebuild.extraFields(extra).first { $0.id == 0x9901 })
                bytes.zipSet(method, at: start + field.range.lowerBound + 9)
            }
        } else {
            bytes.zipSet(method, at: Int(raw.recordRange.lowerBound) + 8)
            bytes.zipSet(method, at: Int(layout.centralOffset) + 10)
        }
        try bytes.write(to: url)
    }

    func testUnknownMethodOnlyRequiresDecompressionForPassAOrV2() throws {
        let directory = try directory("unknown")
        for (label, current, encryption, length) in [
            ("plain-small", nil, ZipEncryption.aes256, 1), ("plain-large", nil, .aes256, 50),
            ("ae1", Optional("old"), .aes256, 1), ("ae2", Optional("old"), .aes256, 50),
            ("zc", Optional("old"), .zipCrypto, 50)
        ] {
            let source = try ReencryptionSupport.fixture(directory, name: label + ".zip", password: current, encryption: encryption,
                method: .stored, items: [("opaque", Data(repeating: 1, count: length))])
            try setMethod(96, in: source)
            for mode in 0..<3 {
                let fails = label == "zc" || (label == "plain-large" && mode == 2) || (label == "ae2" && mode != 2)
                if fails {
                    try ReencryptionSupport.assertFailure(source, password: mode == 0 ? nil : "new", current: current,
                        encryption: mode == 1 ? .zipCrypto : .aes256)
                } else {
                    let output = directory.appendingPathComponent(label + "-\(mode).zip")
                    try ReencryptionSupport.convert(source, to: output, current: current, password: mode == 0 ? nil : "new",
                        encryption: mode == 1 ? .zipCrypto : .aes256)
                    try ReencryptionSupport.assertStoredEqual(source, output, current: current, password: mode == 0 ? nil : "new", expanded: false)
                }
            }
        }
    }

    func testEncryptedDirectoriesAndSymlinksBecomePlainWithoutChangingPayload() throws {
        let directory = try directory("kinds")
        for mode: UInt16 in [0o40755, 0o120777] {
            let source = try ReencryptionSupport.fixture(directory, name: "\(mode).zip", password: "old", method: .stored,
                items: [("special", Data(repeating: 120, count: 25))])
            let layout = try ZipUpdateLayout(source: ZipUpdateSource(url: source))
            var bytes = try Data(contentsOf: source)
            bytes.zipSet(UInt32(mode) << 16, at: Int(layout.centralOffset) + 38)
            if mode == 0o40755 {
                // directory は末尾 / で判定する。長さを保ち payload 位置を変えない。
                bytes[30 + "special".utf8.count - 1] = 47
                bytes[Int(layout.centralOffset) + 46 + "special".utf8.count - 1] = 47
            }
            try bytes.write(to: source)
            let output = directory.appendingPathComponent("\(mode)-out.zip")
            try ReencryptionSupport.convert(source, to: output, current: "old", password: "new")
            let reader = try ReencryptionSupport.reader(output)
            XCTAssertEqual(reader.entries[0].kind, mode == 0o40755 ? .directory : .symlink)
            XCTAssertFalse(reader.entries[0].isEncrypted)
            try ReencryptionSupport.assertStoredEqual(source, output, current: "old", password: nil)
        }
    }

    func testSaltsAreUniqueAcrossEntriesAndRunsAndSamplingIsBounded() throws {
        let directory = try directory("salts")
        let source = try ReencryptionSupport.fixture(directory, items: (0..<40).map { ("file-\($0)", Data([1])) })
        var salts: Set<Data> = []
        for run in 0..<2 {
            let output = directory.appendingPathComponent("out-\(run).zip")
            let events = ZipIOEvents()
            try ZipReencryption.$testingObserver.withValue({ event in if event.phase == .v3 { events.write(UInt64(event.index), 0) } }) {
                try ReencryptionSupport.convert(source, to: output, current: nil, password: "new")
            }
            XCTAssertEqual(events.events.count, 16)
            XCTAssertEqual(events.events.first?.offset, 0); XCTAssertEqual(events.events.last?.offset, 39)
            let reader = try ReencryptionSupport.reader(output), source = try ZipUpdateSource(url: output)
            for entry in reader.entries {
                let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: entry.index))
                XCTAssertTrue(salts.insert(try source.bytes(at: raw.payloadRange.lowerBound, count: 16)).inserted)
            }
        }
    }

    func testZIP64EntryCounts65535And65536() throws {
        let directory = try directory("counts")
        for count in [65_535, 65_536] {
            let source = directory.appendingPathComponent("source-\(count).zip")
            let writer = try ArchiveWriter.create(url: source, options: .init(compressionMethod: .stored))
            for index in 0..<count { try writer.add(data: Data(), as: "f-\(index)", modificationDate: ZipTestSupport.date) }
            try writer.finish()
            let output = directory.appendingPathComponent("out-\(count).zip")
            try ReencryptionSupport.convert(source, to: output, current: nil, password: "new", encryption: .zipCrypto)
            let reader = try ReencryptionSupport.reader(output, password: "new")
            XCTAssertEqual(reader.entries.count, count)
            for entry in reader.entries { XCTAssertEqual(try reader.read(entry), Data()); XCTAssertTrue(entry.isEncrypted) }
            try EncryptionTestSupport.run(["t", "-pnew", output.path], archive: output, log: "7zz-\(count)")
        }
    }

    private func requireLarge() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_LARGE_ZIP_TESTS"] == "1" else {
            throw XCTSkip("Set GYOSHUKU_LARGE_ZIP_TESTS=1 on a volume with at least 10 GiB free")
        }
    }

    private func sparse(_ url: URL, size: UInt64, tailDescriptor: Bool = false, tailDirectory: Bool = false) throws {
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        size=int(sys.argv[2]); dd=sys.argv[3]=='true'; directory=sys.argv[4]=='true'
        crc=0; remaining=size; zeros=b'\0'*(1024*1024)
        while remaining:
            n=min(remaining,len(zeros));crc=zlib.crc32(zeros[:n],crc);remaining-=n
        def local(name,size,crc,dd=False,offset=0):return p('IHHHHHIIIHH',0x04034b50,45 if offset>=0xffffffff else 20,0x808 if dd else 0x800,0,0,0x21,0 if dd else crc,0 if dd else size,0 if dd else size,len(name),0)+name
        def central(name,size,crc,offset,dd=False):
            extra=p('HHQ',1,8,offset) if offset>=0xffffffff else b''
            return p('IHHHHHHIIIHHHHHII',0x02014b50,0x314,45 if extra else 20,0x808 if dd else 0x800,0,0,0x21,crc,size,size,len(name),len(extra),0,0,0,(0o40755 if name.endswith(b'/') else 0o100644)<<16,min(offset,0xffffffff))+name+extra
        name=b'tail/' if directory else b'tail';data=b'tail-data';tailcrc=zlib.crc32(data)
        with open(sys.argv[1],'wb') as f:
            f.write(local(b'x',size,crc));f.seek(31+size);offset=f.tell()
            f.write(local(name,len(data),tailcrc,dd,offset)+data)
            if dd:f.write(p('IIII',0x08074b50,tailcrc,len(data),len(data)))
            cdo=f.tell();cd=central(b'x',size,crc,0)+central(name,len(data),tailcrc,offset,dd);f.write(cd)
            if cdo>=0xffffffff:
                end64=f.tell();f.write(p('IQHHIIQQQQ',0x06064b50,44,0x33f,45,0,0,2,2,len(cd),cdo));f.write(p('IIQI',0x07064b50,0,end64,1))
            f.write(p('IHHHHIIH',0x06054b50,0,0,2,2,len(cd),min(cdo,0xffffffff),0))
        """#
        try ZipTestSupport.run(ReferenceTool.python3, ["-c", script, url.path, String(size), String(tailDescriptor), String(tailDirectory)],
            in: url.deletingLastPathComponent(), log: "sparse")
    }

    func testLargeAESSizeCrossingAndRemoval() throws {
        try requireLarge()
        let directory = try directory("large-size"), source = directory.appendingPathComponent("source.zip")
        try sparse(source, size: ZipRecords.limit - 20)
        let encrypted = directory.appendingPathComponent("aes.zip")
        try ReencryptionSupport.convert(source, to: encrypted, current: nil, password: "new")
        let aes = try ReencryptionSupport.reader(encrypted)
        XCTAssertTrue(try XCTUnwrap(aes.zipRawRecordLayout(at: 0)).localHasZIP64Extra)
        XCTAssertGreaterThan(try XCTUnwrap(aes.zipRawRecordLayout(at: 1)).recordRange.lowerBound, ZipRecords.limit)
        let restored = directory.appendingPathComponent("restored.zip")
        try ReencryptionSupport.convert(encrypted, to: restored, current: "new", password: nil)
        XCTAssertFalse(try XCTUnwrap(ReencryptionSupport.reader(restored).zipRawRecordLayout(at: 0)).localHasZIP64Extra)
        try ZipP1Support.assertEqualFiles(source, restored)
        try EncryptionTestSupport.run(["t", "-pnew", encrypted.path], archive: encrypted, log: "large-7zz")
    }

    func testLargeConvertedDescriptorCrossesButCarriedDescriptorRefuses() throws {
        try requireLarge()
        let directory = try directory("large-descriptor")
        for isDirectory in [false, true] {
            let source = directory.appendingPathComponent("source-\(isDirectory).zip")
            try sparse(source, size: ZipRecords.limit - 35, tailDescriptor: true, tailDirectory: isDirectory)
            let original = directory.appendingPathComponent("original-\(isDirectory).zip")
            try FileManager.default.copyItem(at: source, to: original)
            let updater = try ArchiveUpdater.open(url: source, options: .init(password: "new"))
            try updater.reencryptExistingEntries(currentPassword: nil)
            if isDirectory {
                XCTAssertThrowsError(try updater.commit()) { error in
                    guard case UpdaterError.nonRelocatableEntry(index: 1, name: _, reason: _) = error else { return XCTFail("\(error)") }
                }
                try ZipP1Support.assertEqualFiles(source, original)
            } else {
                try updater.commit()
                let raw = try XCTUnwrap(ReencryptionSupport.reader(source).zipRawRecordLayout(at: 1))
                XCTAssertGreaterThan(raw.recordRange.lowerBound, ZipRecords.limit); XCTAssertFalse(raw.hasDataDescriptor)
                try EncryptionTestSupport.run(["t", "-pnew", source.path], archive: source, log: "descriptor-7zz")
            }
        }
    }

    func testLarge300MiBPayloadReadsAtMostOneMiB() throws {
        try requireLarge()
        let directory = try directory("large-reads"), source = directory.appendingPathComponent("source.zip")
        try sparse(source, size: 300 * 1024 * 1024)
        let inode = UInt64(try ZipP1Support.info(source).st_ino)
        let updater = try ArchiveUpdater.open(url: source, options: .init(password: "new", zipEncryption: .zipCrypto))
        try updater.reencryptExistingEntries(currentPassword: nil)
        let events = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(events.read) { try updater.commit() }
        XCTAssertTrue(events.events.filter { $0.inode == inode }.allSatisfy { $0.count <= 1_048_576 })
    }
}
