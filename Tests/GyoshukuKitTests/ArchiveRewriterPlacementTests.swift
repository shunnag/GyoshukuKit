import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterPlacementTests: XCTestCase {
    func testBothPlacementsInAllFormatsAndDeferredOutput() throws {
        let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]
        for format in formats {
            for placement in [AdditionPlacement.end, .beginning] {
                let root = try ZipTestSupport.directory("p2-placement-\(format)-\(placement)")
                let source = try TarP2Support.fixture(root, count: 3)
                let work = try TarP2Support.work(root), output = work.appendingPathComponent("output." + TarP2Support.suffix(format))
                let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format,
                                                       options: .init(additionPlacement: placement))
                try rewriter.remove(entriesAt: [1])
                try rewriter.rename(entryAt: 2, to: "renamed")
                try rewriter.add(data: Data([9, 8]), as: "added", modificationDate: ZipTestSupport.date)
                try rewriter.addDirectory("dir", modificationDate: ZipTestSupport.date, ownerIDs: nil)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, placement == .end)
                var carried: [Int] = []
                try rewriter.commit { completed, total in XCTAssertEqual(total, 2); carried.append(completed) }
                XCTAssertEqual(carried, [1, 2])
                let reader = try ArchiveReader.open(url: output)
                XCTAssertEqual(reader.entries.map(\.name), placement == .end
                    ? ["file-000000", "renamed", "added", "dir/"] : ["added", "dir/", "file-000000", "renamed"])
                let directory = try XCTUnwrap(reader.entries.first { $0.kind == .directory })
                XCTAssertEqual(directory.modificationDate, ZipTestSupport.date)
                XCTAssertEqual(directory.posixPermissions, 0o755)
                XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "added" })), Data([9, 8]))
            }
        }
    }

    func testQueuedSourceIdentityAndImmediateReservationFailures() throws {
        for mutation in 0..<5 {
            let root = try ZipTestSupport.directory("p2-queued-source-\(mutation)")
            let source = try TarP2Support.fixture(root)
            let before = try Data(contentsOf: source)
            let work = try TarP2Support.work(root), output = work.appendingPathComponent("out.tar")
            let disk = root.appendingPathComponent("disk")
            try Data([1, 2]).write(to: disk)
            let editor = try ArchiveRewriter.open(url: source, output: output, format: .tar)
            if mutation == 4 { try FileManager.default.removeItem(at: disk) }
            if mutation == 4 {
                XCTAssertThrowsError(try editor.add(contentsOf: disk, as: "added")) {
                    guard case WriterError.io = $0 else { return XCTFail("\($0)") }
                }
            } else {
                try editor.add(contentsOf: disk, as: "added")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
                switch mutation {
                case 0: try Data([1, 2, 3]).write(to: disk)
                case 1: try FileManager.default.removeItem(at: disk)
                case 2:
                    XCTAssertThrowsError(try editor.rename(entryAt: 0, to: "added")) { XCTAssertEqual($0 as? WriterError, .duplicatePath("added")) }
                default:
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: disk.path)
                }
                if mutation != 2 {
                    XCTAssertThrowsError(try editor.commit()) {
                        if mutation == 1 { guard case WriterError.io = $0 else { return XCTFail("\($0)") } }
                        else { XCTAssertEqual($0 as? WriterError, .sourceChanged(disk.path)) }
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
}

final class ArchiveOwnerIDsTests: XCTestCase {
    func testTarUpdaterKeepsCarriedOwnersRegardlessOfDiskPolicy() throws {
        for preserve in [false, true] {
            let root = try ZipTestSupport.directory("p2-tar-owner-policy-\(preserve)")
            let source = root.appendingPathComponent("source.tar")
            try TarP2Support.archive([(.init(name: Data("owned".utf8), uid: 123, gid: 456), Data())], at: source)
            let disk = root.appendingPathComponent("disk")
            try Data([1]).write(to: disk)
            let output = root.appendingPathComponent("out.tar")
            let editor = try TarUpdater.open(url: source, output: output, options: .init(preserveOwnerIDs: preserve))
            try editor.add(contentsOf: disk, as: "added")
            try editor.commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries[0].formatSpecific["uid"], "123")
            XCTAssertEqual(reader.entries[0].formatSpecific["gid"], "456")
            let info = try ZipP1Support.info(disk)
            XCTAssertEqual(reader.entries[1].formatSpecific["uid"], preserve ? String(info.st_uid) : "0")
            XCTAssertEqual(reader.entries[1].formatSpecific["gid"], preserve ? String(info.st_gid) : "0")
        }
    }

    func testCarryAndDiskOwnersAreIndependentAcrossTarFormats() throws {
        for format in [GyoshukuKit.ArchiveFormat.tar, .tarGzip, .tarBzip2, .tarXZ] {
            for keep in [false, true] {
                for preserve in [false, true] {
                    let root = try ZipTestSupport.directory("p2-owners-\(format)-\(keep)-\(preserve)")
                    let source = root.appendingPathComponent("source.tar")
                    try TarP2Support.archive([(.init(name: Data("owned".utf8), uid: 123, gid: 456), Data())], at: source)
                    let disk = root.appendingPathComponent("disk")
                    try Data([1]).write(to: disk)
                    let output = root.appendingPathComponent("output." + TarP2Support.suffix(format))
                    let editor = try ArchiveRewriter.open(url: source, output: output, format: format,
                        options: .init(preserveOwnerIDs: preserve, carriedTarOwnerIDs: keep ? .keep : .reset))
                    try editor.add(contentsOf: disk, as: "added")
                    try editor.commit()
                    let reader = try ArchiveReader.open(url: output)
                    XCTAssertEqual(reader.entries[0].formatSpecific["uid"], keep ? "123" : "0")
                    XCTAssertEqual(reader.entries[0].formatSpecific["gid"], keep ? "456" : "0")
                    let info = try ZipP1Support.info(disk)
                    XCTAssertEqual(reader.entries[1].formatSpecific["uid"], preserve ? String(info.st_uid) : "0")
                    XCTAssertEqual(reader.entries[1].formatSpecific["gid"], preserve ? String(info.st_gid) : "0")
                }
            }
        }
    }

    func testExplicitOwnersThroughAllEditorExistentialsAndRecursiveDiskAddition() throws {
        for mode in 0..<5 {
            let root = try ZipTestSupport.directory("p2-explicit-owners-\(mode)")
            let format: GyoshukuKit.ArchiveFormat = mode == 0 ? .zip : .tar
            let source = try TarP2Support.fixture(root, count: 1, format: format)
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
            try editor.addDirectory("explicit", modificationDate: ZipTestSupport.date, ownerIDs: ids)
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
            XCTAssertEqual(explicit.modificationDate, ZipTestSupport.date)
        }
    }

    func testUnsupportedOwnersAndProtocolDefaults() throws {
        for format in [GyoshukuKit.ArchiveFormat.sevenZip, .lha] {
            for placement in [AdditionPlacement.end, .beginning] {
                let root = try ZipTestSupport.directory("p2-unsupported-owners-\(format)-\(placement)")
                let source = try TarP2Support.fixture(root)
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
