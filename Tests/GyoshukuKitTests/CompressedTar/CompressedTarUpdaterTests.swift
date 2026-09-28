import Foundation
import Darwin
import Synchronization
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarUpdaterTests: XCTestCase {
    func testOperationsMatchP2AndK5ForAllCodecs() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.directory("compressed-tar-ops-\(format)")
            let source = try CompressedTarTestSupport.fixture(root, format)
            for operation in ["unchanged", "delete-first", "delete-last", "rename-same", "rename-long", "append", "replace", "all"] {
                let output = root.appendingPathComponent(operation + "." + format.testFileExtension)
                let result = try CompressedTarTestSupport.edit(source, format: format, output: output) { editor in
                    switch operation {
                    case "delete-first": try editor.remove(entriesAt: [0])
                    case "delete-last": try editor.remove(entriesAt: [26])
                    case "rename-same": try editor.rename(entryAt: 0, to: "large-C")
                    case "rename-long": try editor.rename(entryAt: 2, to: String(repeating: "r", count: 180))
                    case "append": try editor.add(data: Data(repeating: 77, count: 4096), as: "added", modificationDate: TestSupport.date, permissions: nil)
                    case "replace":
                        try editor.add(data: Data([3]), as: "new", modificationDate: TestSupport.date, permissions: nil)
                        try editor.remove(entriesAt: [0, 3]); try editor.rename(entryAt: 1, to: "next")
                    case "all": try editor.remove(entriesAt: Array(0..<27))
                    default: break
                    }
                }
                if operation == "unchanged" {
                    XCTAssertEqual(result.strategy, .unchanged)
                    XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
                } else if operation == "all" {
                    XCTAssertEqual(result.strategy, .fullEncode(.noReusableChunk))
                    _ = try CompressedTarTestSupport.edit(output, format: format, output: root.appendingPathComponent("from-empty")) {
                        try $0.add(data: Data([1]), as: "restored", modificationDate: TestSupport.date, permissions: nil)
                    }
                } else if operation != "replace" {
                    guard case .splice = result.strategy else { return XCTFail("expected splice: \(format) \(operation) \(result.strategy)") }
                    if operation == "append" { XCTAssertEqual(result.reencodedOldImageBytes, 0) }
                    if operation == "delete-first", format != .tarGzip {
                        XCTAssertEqual(result.reencodedOldImageBytes, 0)
                        TestSupport.report("TAR-WHOLE-DELETE \(format)\treencoded_old=\(result.reencodedOldImageBytes)\treencoded=\(result.reencodedImageBytes)")
                    }
                }
            }
        }
    }
    func testOpenGatesCreateNothingAndAssessmentIsReadOnly() throws {
        let root = try TestSupport.directory("compressed-tar-gates")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip, large: false)
        let output = root.appendingPathComponent("output")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let reader = try CompressedTarTestSupport.open(source)
        let assessment = try XCTUnwrap(CompressedTarUpdater.assess(reader: reader))
        XCTAssertEqual(assessment.format, .tarGzip)
        XCTAssertTrue(assessment.framingReusable)
        for options in [WriterOptions(additionPlacement: .beginning), WriterOptions(carriedTarOwnerIDs: .reset)] {
            XCTAssertThrowsError(try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tarGzip, options: options)) {
                guard case TarUpdaterError.requiresRewrite = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tar))
        XCTAssertThrowsError(try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tarXZ))
        XCTAssertThrowsError(try CompressedTarUpdater.open(reader: ArchiveReader.open(url: source), output: output, format: .tarGzip))
        try TarLayout.$testingKaitoKitMismatch.withValue(true) {
            XCTAssertThrowsError(try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tarGzip))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), before)
        XCTAssertNil(CompressedTarUpdater.assess(reader: try ArchiveReader.open(url: source)))
    }
    func testMissingIdentityRecoveryAndLegacyNamesRequireRewrite() throws {
        let root = try TestSupport.directory("compressed-tar-gates-layout")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip, large: false)
        let output = root.appendingPathComponent("bad")
        let memory = try ArchiveReader.open(source: DataByteSource(data: Data(contentsOf: source)), sourceURL: source,
                                            options: CompressedTarTestSupport.readerOptions)
        XCTAssertNil(CompressedTarUpdater.assess(reader: memory))
        XCTAssertThrowsError(try CompressedTarUpdater.open(reader: memory.reopen(), output: output, format: .tarGzip))
        var recovery = CompressedTarTestSupport.readerOptions; recovery.recoverDamagedArchives = true
        let recovered = try ArchiveReader.open(url: source, options: recovery)
        XCTAssertNil(CompressedTarUpdater.assess(reader: recovered))
        XCTAssertThrowsError(try CompressedTarUpdater.open(reader: recovered.reopen(), output: output, format: .tarGzip))
        for legacy in [true, false] {
            let raw = root.appendingPathComponent("gate-\(legacy).tar")
            let name = legacy ? Data([0x93, 0xfa, 0x96, 0x7b]) : Data("name".utf8)
            let global = legacy ? Data() : TarEditTestSupport.extensionBytes(0x67, TarRecords.paxRecord("uname", value: Data("alice".utf8)))
            try (global + TarRecords.Entry(name: name).ustar() + Data(count: 1024)).write(to: raw)
            let compressed = root.appendingPathComponent("gate-\(legacy).tar.gz")
            try CompressedTarTestSupport.compress(raw, to: compressed, format: .tarGzip, aligned: false)
            let reader = try CompressedTarTestSupport.open(compressed)
            if legacy {
                XCTAssertNotNil(reader.nameEncoding)
                XCTAssertNil(CompressedTarUpdater.assess(reader: reader))
            } else { XCTAssertNotNil(CompressedTarUpdater.assess(reader: reader)) }
            XCTAssertThrowsError(try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: .tarGzip)) {
                guard case TarUpdaterError.requiresRewrite = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testOwnerDateAndReservationsUseAppendFactory() throws {
        let root = try TestSupport.directory("compressed-tar-owners")
        let source = try CompressedTarTestSupport.fixture(root, .tarGzip, large: false)
        let disk = root.appendingPathComponent("disk")
        try Data([7, 8]).write(to: disk)
        _ = try CompressedTarTestSupport.edit(source, format: .tarGzip, output: root.appendingPathComponent("out")) {
            try $0.remove(entriesAt: [2])
            try $0.add(contentsOf: disk, as: "item-000", ownerIDs: .init(user: 123, group: 456))
            try $0.addDirectory("folder", modificationDate: TestSupport.date, ownerIDs: .init(user: 789, group: 987))
        }
        let reader = try CompressedTarTestSupport.open(root.appendingPathComponent("out"))
        XCTAssertEqual(reader.entries.suffix(2).map { $0.formatSpecific["uid"] }, ["123", "789"])
        let editor = try CompressedTarUpdater.open(reader: reader.reopen(), output: root.appendingPathComponent("bad"), format: .tarGzip)
        try editor.add(data: Data(), as: "reserved")
        XCTAssertThrowsError(try editor.rename(entryAt: 0, to: "reserved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }
}
