import Foundation
import Darwin
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterRefusalTests: XCTestCase {
    func testStructuralRoutesAndAssessAgree() throws {
        let root = try TestSupport.directory("7z-refusals")
        for (name, reason) in [("sfx", "sfx prefix"), ("packpos16", "pack position gap"),
            ("archive_properties", "header: archiveProperties"), ("external_names", "header: additionalStreams"),
            ("comment", "header: unknownFileProperty(0x16)"), ("unknown_1a", "header: unknownFileProperty(0x1A)")] {
            let source = SevenZipEditSupport.fixture(name)
            let before = try Data(contentsOf: source)
            let info = try ZipEditTestSupport.info(source)
            let work = try TestSupport.work(in: root)
            XCTAssertThrowsError(try SevenZipUpdater.open(url: source, output: work.appendingPathComponent("output.7z")), name) {
                XCTAssertEqual($0 as? UpdaterRouteError, .requiresRewrite(reason: reason), name)
            }
            let assessment = SevenZipUpdater.assess(reader: try SevenZipEditSupport.reader(source))
            XCTAssertEqual(assessment?.reason, reason, name)
            XCTAssertEqual(assessment?.updatable, false, name)
            XCTAssertEqual(assessment?.canReencrypt, false, name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
            XCTAssertEqual(try Data(contentsOf: source), before)
            let after = try ZipEditTestSupport.info(source)
            XCTAssertEqual(after.st_ino, info.st_ino)
            XCTAssertEqual(after.st_mtimespec.tv_sec, info.st_mtimespec.tv_sec)
            XCTAssertEqual(after.st_mtimespec.tv_nsec, info.st_mtimespec.tv_nsec)
        }
    }
    func testSettingsNamesMismatchAndNon7z() throws {
        let root = try TestSupport.directory("7z-refusal-settings")
        let source = try SevenZipEditSupport.source(root)
        let output = root.appendingPathComponent("output.7z")
        XCTAssertThrowsError(try SevenZipUpdater.open(url: source, output: output, options: WriterOptions(additionPlacement: .beginning))) {
            XCTAssertEqual($0 as? UpdaterRouteError, .requiresRewrite(reason: "additionPlacement"))
        }
        XCTAssertThrowsError(try SevenZipUpdater.open(url: root.appendingPathComponent("source.7z.001"), output: output)) {
            XCTAssertEqual($0 as? UpdaterRouteError, .requiresRewrite(reason: "split volume name"))
        }
        XCTAssertThrowsError(try SevenZipUpdater.$testingLayoutMismatch.withValue(true) { try SevenZipUpdater.open(url: source, output: output) }) {
            XCTAssertEqual($0 as? UpdaterRouteError, .requiresRewrite(reason: "layout mismatch"))
        }
        let assessment = try SevenZipUpdater.$testingLayoutMismatch.withValue(true) {
            SevenZipUpdater.assess(reader: try SevenZipEditSupport.reader(source))
        }
        XCTAssertEqual(assessment?.updatable, false)
        XCTAssertEqual(assessment?.reason, "layout mismatch")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.7z"])
        let zip = root.appendingPathComponent("other.bin")
        let writer = try ArchiveWriter.create(url: zip); try writer.finish()
        XCTAssertThrowsError(try SevenZipUpdater.open(url: zip, output: output)) {
            guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNil(SevenZipUpdater.assess(reader: try ArchiveReader.open(url: source)))
        XCTAssertThrowsError(try SevenZipUpdater.open(url: SevenZipEditSupport.fixture("empty_7zz"), output: output)) {
            XCTAssertTrue($0 is KaitoError)
        }
        let updater = try SevenZipUpdater.open(url: source, output: output)
        XCTAssertThrowsError(try updater.addDirectory("d", modificationDate: nil, ownerIDs: .init(user: 1, group: 2))) {
            XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs"))
        }
        XCTAssertThrowsError(try updater.add(contentsOf: source, as: "d", ownerIDs: .init(user: 1, group: 2))) {
            XCTAssertEqual($0 as? WriterError, .unsupportedOption("ownerIDs"))
        }
        let reader = try SevenZipEditSupport.reader(SevenZipEditSupport.fixture("bcj2"))
        XCTAssertEqual(SevenZipUpdater.assess(reader: reader)?.canReencrypt, false)
        let other = try SevenZipUpdater.open(url: SevenZipEditSupport.fixture("bcj2"), output: root.appendingPathComponent("other.7z"))
        XCTAssertThrowsError(try other.reencryptExistingEntries(currentPassword: nil)) {
            guard case UpdaterError.reencryptionFailed = $0 else { return XCTFail("\($0)") }
        }
    }
}
