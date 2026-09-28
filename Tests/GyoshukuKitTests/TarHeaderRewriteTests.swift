import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

struct TarMemorySource: ByteSource {
    let data: Data
    var length: UInt64 { UInt64(data.count) }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let count = min(buffer.count, data.count - Int(offset))
        data.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: Int(offset)), byteCount: count) }
        return count
    }
}

final class TarHeaderRewriteTests: XCTestCase {
    func testWriterGroupsMatchExactlyAcrossPaxFieldsAndNameBoundaries() throws {
        let names = ["short", String(repeating: "a", count: 100), String(repeating: "a", count: 101),
                     String(repeating: "p", count: 155) + "/" + String(repeating: "b", count: 100), "日本語/new"]
        for old in names {
            for new in names {
                for variant in 0..<4 {
                    var entry = TarRecords.Entry(name: Data(old.utf8), mode: 0o751, mtime: -1)
                    if variant == 1 { entry.size = 9 * 1024 * 1024 * 1024 }
                    if variant == 2 { entry.uid = .max; entry.gid = .max }
                    if variant == 3 { entry.type = 0x32; entry.link = Data(String(repeating: "l", count: 101).utf8) }
                    let bytes = entry.headers()
                    let unit = TarLayout.Unit(groupStart: 0, headerStart: UInt64(bytes.count - 512), dataStart: UInt64(bytes.count),
                                              storedSize: entry.size, paddedEnd: UInt64(bytes.count) + entry.size,
                                              typeFlag: entry.type, flags: 0)
                    let rewritten = try TarHeaderRewrite.rewrite(source: TarMemorySource(data: bytes), unit: unit,
                                                                 name: Data(new.utf8), link: nil, materializedSize: nil)
                    entry.name = Data(new.utf8)
                    XCTAssertEqual(rewritten, entry.headers(), "\(old) -> \(new), variant \(variant)")
                }
            }
        }
    }

    func testMaterializationInsertsSizeAfterPathAndClearsLink() throws {
        var entry = TarRecords.Entry(name: Data("old".utf8), uid: .max, type: 0x31, link: Data("target".utf8))
        let original = entry.headers()
        let unit = TarLayout.Unit(groupStart: 0, headerStart: UInt64(original.count - 512), dataStart: UInt64(original.count),
                                  storedSize: 0, paddedEnd: UInt64(original.count), typeFlag: 0x31, flags: 0)
        entry.name = Data(String(repeating: "n", count: 200).utf8)
        entry.type = 0x30
        entry.size = 9 * 1024 * 1024 * 1024
        entry.link = Data()
        XCTAssertEqual(try TarHeaderRewrite.rewrite(source: TarMemorySource(data: original), unit: unit,
            name: entry.name, link: nil, materializedSize: entry.size), entry.headers())
    }

    func testGNUAndV7KeepNonPOSIXPrefixFieldsAndLongExtensions() throws {
        for magic in [Data(count: 8), Data("ustar  \0".utf8)] {
            var header = TarRecords.Entry(name: Data("old".utf8)).ustar()
            header.replaceSubrange(257..<265, with: magic)
            header.replaceSubrange(345..<500, with: Data(repeating: 55, count: 155))
            TarP2Support.checksum(&header)
            let longLink = TarP2Support.extensionBytes(0x4b, Data(String(repeating: "k", count: 150).utf8) + Data([0]))
            let longName = TarP2Support.extensionBytes(0x4c, Data(String(repeating: "old", count: 50).utf8) + Data([0]))
            let bytes = longLink + longName + header
            let unit = TarLayout.Unit(groupStart: 0, headerStart: UInt64(bytes.count - 512), dataStart: UInt64(bytes.count),
                                      storedSize: 0, paddedEnd: UInt64(bytes.count), typeFlag: 0x30, flags: 0)
            let name = Data((String(repeating: "a", count: 120) + "/leaf").utf8)
            let changed = try TarHeaderRewrite.rewrite(source: TarMemorySource(data: bytes), unit: unit, name: name, link: nil, materializedSize: nil)
            let h = Data(changed.suffix(512))
            XCTAssertEqual(h[345..<500], header[345..<500])
            XCTAssertEqual(h[0..<100], name.prefix(100))
            XCTAssertNotNil(changed.range(of: longLink))
            XCTAssertNil(changed.range(of: longName))
        }
    }

    func testOrderedRepeatedPaxAndSparseAllVersions() throws {
        let root = try TestSupport.directory("p2-sparse")
        for version in ["0.0", "0.1", "1.0"] {
            for named in [false, true] {
                var fields = [("path", "discarded"), ("path", ""), ("SCHILY.xattr.user.test", "one"),
                              ("SCHILY.xattr.user.test", "two")]
                if named { fields += [("GNU.sparse.name", "old-parent/old-leaf"), ("GNU.sparse.name", "old-parent/old-leaf")] }
                var payload = Data("abcd".utf8)
                if version == "1.0" {
                    fields += [("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0"), ("GNU.sparse.realsize", "10")]
                    let map = Data("2\n0\n2\n8\n2\n".utf8)
                    payload = map + Data(count: 512 - map.count) + payload
                } else {
                    fields += [("GNU.sparse.size", "10"), ("GNU.sparse.numblocks", "2")]
                    fields += version == "0.1" ? [("GNU.sparse.map", "0,2,8,2")]
                        : [("GNU.sparse.offset", "0"), ("GNU.sparse.numbytes", "2"), ("GNU.sparse.offset", "8"), ("GNU.sparse.numbytes", "2")]
                }
                let pax = fields.reduce(Data()) { $0 + TarRecords.paxRecord($1.0, value: Data($1.1.utf8)) }
                let source = root.appendingPathComponent("\(version)-\(named).tar")
                let header = TarRecords.Entry(name: Data("old-parent/GNUSparseFile.123/old-leaf".utf8), size: UInt64(payload.count)).ustar()
                let bytes = TarP2Support.extensionBytes(0x58, pax) + header + payload + Data(count: TarRecords.padding(UInt64(payload.count))) + Data(count: 1024)
                try bytes.write(to: source)
                let output = root.appendingPathComponent("out-\(version)-\(named).tar")
                let updater = try TarUpdater.open(url: source, output: output)
                try updater.rename(entryAt: 0, to: "new-parent/new-leaf")
                try updater.commit()
                let (layout, data, reader) = try TarP2Support.scan(output)
                XCTAssertEqual(reader.entries[0].name, "new-parent/new-leaf")
                XCTAssertEqual(try reader.read(reader.entries[0]), Data("ab".utf8) + Data(count: 6) + Data("cd".utf8))
                let group = try TarLayout.group(source: data, unit: layout.member(0))
                XCTAssertEqual(group.records.filter { $0.key == "SCHILY.xattr.user.test" }.map(\.value), [Data("one".utf8), Data("two".utf8)])
                if version == "0.0" { XCTAssertEqual(group.records.filter { $0.key == "GNU.sparse.offset" }.map(\.value), [Data("0".utf8), Data("8".utf8)]) }
                if named {
                    XCTAssertEqual(group.records.filter { $0.key == "GNU.sparse.name" }.count, 1)
                    XCTAssertFalse(group.records.contains { $0.key == "path" })
                    XCTAssertEqual(TarLayout.headerName(group.header), Data("new-parent/GNUSparseFile.0/new-leaf".utf8))
                }
                XCTAssertNil(try Data(contentsOf: output).range(of: Data("old-parent".utf8)))
                if named && version != "0.0" {
                    let script = "import tarfile,sys; t=tarfile.open(sys.argv[1]); assert t.getnames()==['new-parent/new-leaf']; assert t.extractfile(t.getmembers()[0]).read()==b'ab'+bytes(6)+b'cd'"
                    try TestSupport.run(ReferenceTool.python3, ["-c", script, output.path], in: root, log: "sparse-python-\(version)")
                    let listing = try TestSupport.run(ReferenceTool.bsdtar, ["-tf", output.path], in: root, log: "sparse-bsd-\(version)")
                    XCTAssertEqual(listing, "new-parent/new-leaf\n")
                }
            }
        }
    }
}

final class TarLayoutTests: XCTestCase {
    func testSignedChecksumAndNumericFields() throws {
        var header = TarRecords.Entry(name: Data("name".utf8), size: 9 * 1024 * 1024 * 1024).ustar()
        header[265] = 0xff
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let signed = header.reduce(Int64(0)) { $0 + Int64(Int8(bitPattern: $1)) }
        TarRecords.number(UInt64(signed), in: &header, at: 148, width: 7)
        header[155] = 32
        XCTAssertNoThrow(try TarLayout.validateChecksum(header))
        XCTAssertEqual(try TarLayout.number(header, range: 124..<136), 9 * 1024 * 1024 * 1024)
        XCTAssertEqual(try TarLayout.number(Data("  17\0  ".utf8)), 15)
        XCTAssertThrowsError(try TarLayout.number(Data("1 7".utf8)))
        XCTAssertThrowsError(try TarLayout.number(Data([0xff, 0, 1])))
        header[0] ^= 1
        XCTAssertThrowsError(try TarLayout.validateChecksum(header))
    }

    func testGenericByteSourceUnitsAndBoundedHeaderReads() throws {
        let root = try TestSupport.directory("p2-layout")
        let source = try TarP2Support.fixture(root, count: 20, size: 64 * 1024)
        let data = try Data(contentsOf: source)
        let (_, disk, reader) = try TarP2Support.scan(source)
        let reads = ZipIOEvents()
        let layout = try ZipUpdateSource.$readObserver.withValue(reads.read) {
            try TarLayout.scan(source: disk, length: disk.length, entries: reader.entries, nameEncoding: reader.nameEncoding,
                               hardLinkTargets: [:], dataTargets: [:])
        }
        XCTAssertEqual(layout.units.count, 20)
        XCTAssertLessThanOrEqual(MemoryLayout<TarLayout.Unit>.stride, 48)
        XCTAssertTrue(reads.events.allSatisfy { $0.count <= 4096 && ($0.offset % (65536 + 512) == 0) })
        let memory = try TarLayout.scan(source: TarMemorySource(data: data), length: UInt64(data.count), entries: reader.entries,
                                       nameEncoding: nil, hardLinkTargets: [:], dataTargets: [:])
        XCTAssertEqual(memory.membersEnd, layout.membersEnd)
        XCTAssertEqual(memory.units.map(\.groupStart), layout.units.map(\.groupStart))
    }
}

final class TarEditPlanTests: XCTestCase {
    func testContiguousSourcesMergeAndHeaderOnlyPatches() throws {
        let root = try TestSupport.directory("p2-plan")
        let source = try TarP2Support.fixture(root)
        let (layout, disk, reader) = try TarP2Support.scan(source)
        let plan = try TarEditPlan.make(layout: layout, source: disk, names: reader.entries.map(\.name), rawNames: reader.entries.map { Data($0.rawName.bytes) },
                                        hardLinkTargets: [:], dataTargets: [:], removed: [2], renamed: [4: "new"])
        XCTAssertEqual(plan.changed.count, 1)
        XCTAssertEqual(plan.prefix.count, 4)
        XCTAssertEqual(plan.unitOffsets[2], nil)
        XCTAssertEqual(plan.membersEnd, layout.membersEnd - (layout.member(2).paddedEnd - layout.member(2).groupStart))
    }
}
