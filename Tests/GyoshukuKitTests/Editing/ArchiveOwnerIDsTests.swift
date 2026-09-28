import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveOwnerIDsTests: XCTestCase {
    func testTarUpdaterKeepsCarriedOwnersRegardlessOfDiskPolicy() throws {
        for preserve in [false, true] {
            let root = try TestSupport.directory("p2-tar-owner-policy-\(preserve)")
            let source = root.appendingPathComponent("source.tar")
            try TarEditTestSupport.archive([(.init(name: Data("owned".utf8), uid: 123, gid: 456), Data())], at: source)
            let disk = root.appendingPathComponent("disk")
            try Data([1]).write(to: disk)
            let output = root.appendingPathComponent("out.tar")
            let editor = try TarUpdater.open(url: source, output: output, options: .init(preserveOwnerIDs: preserve))
            try editor.add(contentsOf: disk, as: "added")
            try editor.commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries[0].formatSpecific["uid"], "123")
            XCTAssertEqual(reader.entries[0].formatSpecific["gid"], "456")
            let info = try ZipEditTestSupport.info(disk)
            XCTAssertEqual(reader.entries[1].formatSpecific["uid"], preserve ? String(info.st_uid) : "0")
            XCTAssertEqual(reader.entries[1].formatSpecific["gid"], preserve ? String(info.st_gid) : "0")
        }
    }

    func testCarryAndDiskOwnersAreIndependentAcrossTarFormats() throws {
        for format in [GyoshukuKit.ArchiveFormat.tar, .tarGzip, .tarBzip2, .tarXZ] {
            for keep in [false, true] {
                for preserve in [false, true] {
                    let root = try TestSupport.directory("p2-owners-\(format)-\(keep)-\(preserve)")
                    let source = root.appendingPathComponent("source.tar")
                    try TarEditTestSupport.archive([(.init(name: Data("owned".utf8), uid: 123, gid: 456), Data())], at: source)
                    let disk = root.appendingPathComponent("disk")
                    try Data([1]).write(to: disk)
                    let output = root.appendingPathComponent("output." + format.testFileExtension)
                    let editor = try ArchiveRewriter.open(url: source, output: output, format: format,
                        options: .init(preserveOwnerIDs: preserve, carriedTarOwnerIDs: keep ? .keep : .reset))
                    try editor.add(contentsOf: disk, as: "added")
                    try editor.commit()
                    let reader = try ArchiveReader.open(url: output)
                    XCTAssertEqual(reader.entries[0].formatSpecific["uid"], keep ? "123" : "0")
                    XCTAssertEqual(reader.entries[0].formatSpecific["gid"], keep ? "456" : "0")
                    let info = try ZipEditTestSupport.info(disk)
                    XCTAssertEqual(reader.entries[1].formatSpecific["uid"], preserve ? String(info.st_uid) : "0")
                    XCTAssertEqual(reader.entries[1].formatSpecific["gid"], preserve ? String(info.st_gid) : "0")
                }
            }
        }
    }

    func testExplicitOwnersThroughAllEditorExistentialsAndRecursiveDiskAddition() throws {
        for mode in 0..<5 {
            let root = try TestSupport.directory("p2-explicit-owners-\(mode)")
            let format: GyoshukuKit.ArchiveFormat = mode == 0 ? .zip : .tar
            let source = try TarEditTestSupport.fixture(root, count: 1, format: format)
            let output = root.appendingPathComponent("out")
            let editor: any ArchiveEditing
            switch mode {
            case 0: editor = try ArchiveUpdater.open(url: source, output: output)
            case 1, 2: editor = try ArchiveRewriter.open(url: source, output: output, format: .tar,
                                                       options: .init(additionPlacement: mode == 1 ? .beginning : .end))
            default: editor = try TarUpdater.open(url: source, output: output, options: .init(preserveOwnerIDs: mode == 4))
            }
            let disk = root.appendingPathComponent("disk")
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
            try Data([7]).write(to: disk.appendingPathComponent("child"))
            let ids = ArchiveOwnerIDs(user: 3_000_000, group: 4_000_000)
            try editor.add(contentsOf: disk, as: "disk", ownerIDs: ids)
            try editor.addDirectory("explicit", modificationDate: TestSupport.date, ownerIDs: ids)
            try editor.commit()
            let reader = try ArchiveReader.open(url: output)
            for entry in reader.entries where entry.name != "file-000000" {
                if mode == 0 {
                    let zip = ZipBytes(data: try Data(contentsOf: output))
                    var central = zip.central
                    for _ in 0..<entry.index { central += 46 + Int(zip.u16(central + 28)) + Int(zip.u16(central + 30)) + Int(zip.u16(central + 32)) }
                    let owner = ZipBytes(data: try XCTUnwrap(zip.extras(Int(zip.u32(central + 42)), local: true)[0x7875]))
                    XCTAssertEqual(owner.u32(2), ids.user)
                    XCTAssertEqual(owner.u32(7), ids.group)
                } else {
                    XCTAssertEqual(entry.formatSpecific["uid"], String(ids.user))
                    XCTAssertEqual(entry.formatSpecific["gid"], String(ids.group))
                }
            }
            let explicit = try XCTUnwrap(reader.entries.first { $0.name == "explicit/" })
            XCTAssertEqual(explicit.posixPermissions, 0o755)
            XCTAssertEqual(explicit.modificationDate, TestSupport.date)
        }
    }

    func testUnsupportedOwnersAndProtocolDefaults() throws {
        for format in [GyoshukuKit.ArchiveFormat.sevenZip, .lha] {
            for placement in [AdditionPlacement.end, .beginning] {
                let root = try TestSupport.directory("p2-unsupported-owners-\(format)-\(placement)")
                let source = try TarEditTestSupport.fixture(root)
                let editor: any ArchiveEditing = try ArchiveRewriter.open(url: source, output: root.appendingPathComponent("out"), format: format,
                                                                          options: .init(additionPlacement: placement))
                XCTAssertThrowsError(try editor.addDirectory("dir", modificationDate: nil, ownerIDs: .init(user: 1, group: 2))) {
                    XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs"))
                }
            }
        }
        let stub: any ArchiveEditing = LegacyEditor()
        try stub.addDirectory("dir", modificationDate: nil, ownerIDs: nil)
        try stub.add(contentsOf: URL(fileURLWithPath: "/unused"), as: "a", ownerIDs: nil)
        XCTAssertThrowsError(try stub.addDirectory("dir", modificationDate: Date(), ownerIDs: nil)) { XCTAssertEqual($0 as? WriterError, .unsupportedOption("addDirectory")) }
        XCTAssertThrowsError(try stub.add(contentsOf: URL(fileURLWithPath: "/unused"), as: "a", ownerIDs: .init(user: 1, group: 2))) { XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs")) }
    }

    private final class LegacyEditor: ArchiveEditing {
        var entryNames: [String] { [] }
        func add(contentsOf url: URL, as path: String) throws {}
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws {}
        func addDirectory(_ path: String) throws {}
        func remove(entriesAt indices: [Int]) throws {}
        func rename(entryAt index: Int, to path: String) throws {}
        func commit() throws {}
    }
}
