import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterRefusalTests: XCTestCase {
    func testHardLinkRawNameGuardAndLegacyEncodingFallback() throws {
        let root = try TestSupport.directory("p2-raw-link-refusal")
        let source = root.appendingPathComponent("source.tar")
        let raw = Data([0x93, 0xfa, 0x96, 0x7b])
        let file = TarRecords.Entry(name: raw).ustar()
        let link = TarRecords.Entry(name: Data("link".utf8), type: 0x31, link: raw).ustar()
        try (file + link + Data(count: 1024)).write(to: source)
        let data = try ZipUpdateSource(url: source)
        let reader = try ArchiveReader.open(url: source)
        XCTAssertNotNil(reader.nameEncoding)
        let gate = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: .tar, reader: reader)
        // R10 が先に拒否する入力でも、共有 walk の R6 を独立して確かめる。
        XCTAssertThrowsError(try TarLayout.scan(source: data, length: data.length, entries: reader.entries, nameEncoding: nil,
                                                hardLinkTargets: gate.hardLinkTargets, dataTargets: gate.dataTargets)) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R6"))
        }
        let work = try TestSupport.work(in: root)
        XCTAssertThrowsError(try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"))) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R10"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testSettingsNamesAndStructuralRefusalsLeaveNothing() throws {
        let root = try TestSupport.directory("p2-refusals")
        let member = TarRecords.Entry(name: Data("file".utf8)).headers()
        var oldSparse = TarRecords.Entry(name: Data("sparse".utf8), type: 0x53).ustar()
        oldSparse.replaceSubrange(257..<265, with: Data("ustar  \0".utf8))
        TarEditTestSupport.checksum(&oldSparse)
        let hard = TarRecords.Entry(name: Data("link".utf8), size: 1, type: 0x31, link: Data("file".utf8)).headers()
        let local = TarEditTestSupport.extensionBytes(0x78, TarRecords.paxRecord("mtime", value: Data("1".utf8)))
        let global = TarEditTestSupport.extensionBytes(0x67, TarRecords.paxRecord("comment", value: Data("test".utf8)))
        let sparse = TarEditTestSupport.extensionBytes(0x78, TarRecords.paxRecord("GNU.sparse.size", value: Data("0".utf8))
            + TarRecords.paxRecord("GNU.sparse.map", value: Data("0,0".utf8))) + member
        let cases: [(String, Data, WriterOptions, String)] = [
            ("begin.tar", member, .init(additionPlacement: .beginning), "additionPlacement"),
            ("reset.tar", member, .init(carriedTarOwnerIDs: .reset), "carriedTarOwnerIDs"),
            ("global.tar", TarEditTestSupport.extensionBytes(0x67, TarRecords.paxRecord("uid", value: Data("501".utf8))) + member, .init(), "R1"),
            ("pending.tar", local + global + member, .init(), "R1"),
            ("old-sparse.tar", oldSparse, .init(), "R2"),
            ("hard-body.tar", member + hard, .init(), "R3"),
            ("charset.tar", TarEditTestSupport.extensionBytes(0x78, TarRecords.paxRecord("hdrcharset", value: Data("UTF-8".utf8))) + member, .init(), "R4"),
            ("sparse-link.tar", sparse + TarRecords.Entry(name: Data("link".utf8), type: 0x31, link: Data("file".utf8)).headers(), .init(), "R5"),
            ("split.tar.001", member, .init(), "split volume name")
        ]
        for (name, bytes, options, reason) in cases {
            let source = root.appendingPathComponent(name)
            try (bytes + Data(count: 1024)).write(to: source)
            let work = try TestSupport.work(in: root)
            let info = try ZipEditTestSupport.info(source)
            XCTAssertThrowsError(try TarUpdater.open(url: source, output: work.appendingPathComponent("out.tar"), options: options)) {
                guard case TarUpdaterError.requiresRewrite(let text) = $0 else { return XCTFail("\(name): \($0)") }
                XCTAssertTrue(text.contains(reason), "\(name): \(text)")
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes + Data(count: 1024))
            XCTAssertEqual(try ZipEditTestSupport.info(source).st_ino, info.st_ino)
            XCTAssertEqual(try ZipEditTestSupport.info(source).st_mtimespec.tv_nsec, info.st_mtimespec.tv_nsec)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }

    func testMismatchEncodingAndKaitoErrorsStayDistinct() throws {
        let root = try TestSupport.directory("p2-refusal-errors")
        let source = try TarEditTestSupport.fixture(root)
        let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.tar")
        try TarLayout.$testingKaitoKitMismatch.withValue(true) {
            XCTAssertThrowsError(try TarUpdater.open(url: source, output: output)) {
                guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(reason.contains("R8"))
            }
        }
        var cp932 = TarRecords.Entry(name: Data("name".utf8)).ustar()
        cp932.replaceSubrange(0..<4, with: Data([0x93, 0xfa, 0x96, 0x7b]))
        TarEditTestSupport.checksum(&cp932)
        let legacy = root.appendingPathComponent("legacy.tar")
        try (cp932 + Data(count: 1024)).write(to: legacy)
        XCTAssertThrowsError(try TarUpdater.open(url: legacy, output: output)) {
            guard case TarUpdaterError.requiresRewrite(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("R10"))
        }
        let extensionBytes = TarEditTestSupport.extensionBytes(0x78, TarRecords.paxRecord("path", value: Data("file".utf8)))
        for bytes in [extensionBytes + extensionBytes + TarRecords.Entry(name: Data("file".utf8)).headers(), extensionBytes] {
            let malformed = root.appendingPathComponent(UUID().uuidString + ".tar")
            try (bytes + Data(count: 1024)).write(to: malformed)
            XCTAssertThrowsError(try TarUpdater.open(url: malformed, output: output)) { XCTAssertTrue($0 is KaitoError, "\($0)") }
        }
        let gzip = root.appendingPathComponent("gzip.tar")
        let writer = try ArchiveWriter.create(url: gzip, format: .tarGzip)
        try writer.add(data: Data(), as: "file")
        try writer.finish()
        XCTAssertThrowsError(try TarUpdater.open(url: gzip, output: output)) {
            guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
}
