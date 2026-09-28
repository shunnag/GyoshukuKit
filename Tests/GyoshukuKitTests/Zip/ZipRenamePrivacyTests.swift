import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipRenamePrivacyTests: XCTestCase {
    private let oldName = "日本語-旧名.txt"
    private let removedName = "削除-秘密.txt"
    private let payload = Data("carried contents".utf8)

    private func field(_ id: UInt16, _ body: Data) -> Data {
        var result = Data()
        result.le(id)
        result.le(UInt16(body.count))
        return result + body
    }

    private func fixture(riskyExtra: UInt16? = nil, inLocal: Bool = true, centralTail: Data = Data()) throws -> URL {
        let directory = try TestSupport.directory("zip-rename-privacy-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.zip")
        var records = Data(), central = Data()
        for (index, entryName) in [oldName, removedName, "keep.txt"].enumerated() {
            let rawName = try XCTUnwrap(entryName.data(using: .shiftJIS))
            let contents = index == 1 ? Data("deleted private contents".utf8) : payload
            var timestamp = Data([1])
            timestamp.le(UInt32(1_700_000_001))
            var unicode = Data([1])
            unicode.le(CRC32.checksum(rawName))
            unicode.append(contentsOf: entryName.utf8)
            var staleUnicode = unicode
            staleUnicode[0] = 2
            let extras = field(0x5455, timestamp) + field(0x7075, unicode)
                + field(0x7075, staleUnicode) + field(0x7075, Data()) + field(0xCAFE, Data("xyz".utf8))
            let risky = index == 0 ? riskyExtra.map { field($0, Data(entryName.utf8)) } ?? Data() : Data()
            let localExtra = extras + (inLocal ? risky : Data())
            let centralExtra = extras + (inLocal ? Data() : risky) + (index == 0 ? centralTail : Data())
            let offset = UInt32(records.count)
            records.le(UInt32(0x04034B50))
            for value: UInt16 in [20, 0, 0, 0, 0x21] { records.le(value) }
            records.le(CRC32.checksum(contents))
            records.le(UInt32(contents.count))
            records.le(UInt32(contents.count))
            records.le(UInt16(rawName.count))
            records.le(UInt16(localExtra.count))
            records.append(rawName + localExtra + contents)
            central.le(UInt32(0x02014B50))
            for value: UInt16 in [0x0314, 20, 0, 0, 0, 0x21] { central.le(value) }
            central.le(CRC32.checksum(contents))
            central.le(UInt32(contents.count))
            central.le(UInt32(contents.count))
            for value in [UInt16(rawName.count), UInt16(centralExtra.count), 0, 0, 0] { central.le(value) }
            central.le(UInt32(0o100644) << 16)
            central.le(offset)
            central.append(rawName + centralExtra)
        }
        var end = Data()
        end.le(UInt32(0x06054B50))
        for value: UInt16 in [0, 0, 3, 3] { end.le(value) }
        end.le(UInt32(central.count))
        end.le(UInt32(records.count))
        end.le(UInt16(0))
        try (records + central + end).write(to: url)
        return url
    }

    private func assertAbsent(_ names: [String], from bytes: Data,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        for name in names {
            XCTAssertNil(bytes.range(of: Data(name.utf8)), "UTF-8: \(name)", file: file, line: line)
            XCTAssertNil(bytes.range(of: try XCTUnwrap(name.data(using: .shiftJIS))), "CP932: \(name)", file: file, line: line)
        }
    }

    private func assertNeutralized(_ bytes: Data, offset: Int, local: Bool) {
        let parsed = ZipBytes(data: bytes)
        var cursor = offset + (local ? 30 : 46) + Int(parsed.u16(offset + (local ? 26 : 28)))
        let end = cursor + Int(parsed.u16(offset + (local ? 28 : 30)))
        var paddingCount = 0
        while cursor < end {
            let id = parsed.u16(cursor), length = Int(parsed.u16(cursor + 2))
            XCTAssertNotEqual(id, 0x7075)
            if id == 0xFFFF {
                paddingCount += 1
                XCTAssertEqual(bytes.subdata(in: (cursor + 4)..<(cursor + 4 + length)), Data(count: length))
            }
            cursor += 4 + length
        }
        XCTAssertEqual(paddingCount, 3)
    }

    func testOldNamesAbsentAfterRenameRemovalAndStagedAddThroughBothEditors() throws {
        let equalLength = String(repeating: "n", count: try XCTUnwrap(oldName.data(using: .shiftJIS)).count)
        for (rewrite, placement) in [(false, AdditionPlacement.end), (true, .end), (true, .beginning)] {
            for added in [false, true] {
                for newName in ["x", equalLength, "longer-directory/a-much-longer-name.txt"] {
                    let url = try fixture()
                    let beforeReader = try ArchiveReader.open(url: url)
                    let beforeRecord = try XCTUnwrap(beforeReader.rawRecord(of: beforeReader.entries[0]))
                    let editor: any ArchiveEditing = rewrite
                        ? try ArchiveRewriter.open(url: url, format: .zip, options: .init(additionPlacement: placement))
                        : try ArchiveUpdater.open(url: url)
                    let appended = ZipTestSupport.Expected(name: "added.txt", data: Data("appended contents".utf8))
                    if added { try editor.add(data: appended.data, as: appended.name, modificationDate: appended.date, permissions: appended.permissions) }
                    try editor.rename(entryAt: 0, to: "intermediate-private-name.txt")
                    try editor.rename(entryAt: 0, to: newName)
                    try editor.remove(entriesAt: [1])
                    try editor.commit()
                    let after = try Data(contentsOf: url)
                    try assertAbsent([oldName, removedName, "intermediate-private-name.txt"], from: after)
                    XCTAssertNil(after.range(of: Data("deleted private contents".utf8)))
                    if !rewrite {
                        let reader = try ArchiveReader.open(url: url)
                        let record = try XCTUnwrap(reader.rawRecord(of: reader.entries[0]))
                        assertNeutralized(after, offset: Int(record.recordRange.lowerBound), local: true)
                        assertNeutralized(after, offset: ZipBytes(data: after).central, local: false)
                        if newName == equalLength { XCTAssertEqual(record.payloadRange, beforeRecord.payloadRange) }
                    }
                    var expected: [ZipTestSupport.Expected] = [.init(name: newName, data: payload), .init(name: "keep.txt", data: payload)]
                    if added { expected.insert(appended, at: rewrite && placement == .beginning ? 0 : expected.count) }
                    try ZipTestSupport.verify(url, expected: expected)
                }
            }
        }
    }

    func testOtherNameBearingExtrasRefuseRenameWithoutChangingOriginal() throws {
        for id: UInt16 in [0x0008, 0x2605, 0x334D, 0x4F4C, 0x554E] {
            for inLocal in [false, true] {
                for staged in [false, true] {
                    let url = try fixture(riskyExtra: id, inLocal: inLocal)
                    let before = try Data(contentsOf: url)
                    let updater = try ArchiveUpdater.open(url: url)
                    if staged { try updater.add(data: payload, as: "appended.txt") }
                    try updater.rename(entryAt: 0, to: "renamed.txt")
                    XCTAssertThrowsError(try updater.commit()) {
                        XCTAssertEqual($0 as? UpdaterError, .invalidArchive(String(format:
                            "名前を含む ZIP extra field 0x%04X を安全に更新できないため改名できません", id)))
                    }
                    XCTAssertEqual(try Data(contentsOf: url), before)
                    let deletion = try ArchiveUpdater.open(url: url)
                    try deletion.remove(entriesAt: [0, 1])
                    try deletion.commit()
                    try assertAbsent([oldName, removedName], from: Data(contentsOf: url))
                    let reader = try ArchiveReader.open(url: url)
                    XCTAssertEqual(reader.entries.map(\.name), ["keep.txt"])
                    XCTAssertEqual(try reader.read(reader.entries[0]), payload)
                }
            }
        }
    }

    func testUnparsedCentralExtraTailCannotRetainOldNameOnRename() throws {
        var tail = Data()
        tail.le(UInt16(0x7075))
        tail.le(UInt16.max)
        tail.append(contentsOf: oldName.utf8)
        for staged in [false, true] {
            let url = try fixture(centralTail: tail)
            let before = try Data(contentsOf: url)
            let updater = try ArchiveUpdater.open(url: url)
            if staged { try updater.add(data: payload, as: "added.txt") }
            try updater.rename(entryAt: 0, to: "renamed.txt")
            XCTAssertThrowsError(try updater.commit()) {
                XCTAssertEqual($0 as? UpdaterError, .invalidArchive("ZIP extra field の末尾を解析できないため改名できません"))
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
}
