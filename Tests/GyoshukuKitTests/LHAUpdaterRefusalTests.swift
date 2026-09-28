import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterRefusalTests: XCTestCase {
    func testStructuralRefusalsPreserveSourceAndLeaveNoFiles() throws {
        let root = try TestSupport.directory("lha-refusals")
        let cases = [("os9-k-short-level2", "R8"), ("names-euc-jp", "R10"), ("names-utf8-declared", "R10"),
                     ("names-utf8-undeclared", "R10"), ("sfx", "L1"), ("empty-name-directory-tail", "L2"),
                     ("larc-lzs-eof", "L2"), ("tl-S5", "L3"), ("tl-S11", "L3"), ("anonymous-middle", "L4"),
                     ("level3", "L5"), ("data-directories", "L7"), ("lhark-lh7", "L8"), ("level1-large-packed", "L9")]
        for (name, reason) in cases {
            let source = try LHAUpdateSupport.fixture(name, in: root)
            let before = try ZipP1Support.info(source)
            // L9 is sparse: compare its stored prefix and stat, without reading a 4 GiB hole.
            let bytes = try ZipUpdateSource(url: source).bytes(at: 0, count: min(Int(before.st_size), 65536))
            let reader = try ArchiveReader.open(url: source, options: TestSupport.editingReaderOptions)
            let work = try TestSupport.work(in: root)
            XCTAssertThrowsError(try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))) {
                guard case UpdaterRouteError.requiresRewrite(let text) = $0 else { return XCTFail("\(name): \($0)") }
                XCTAssertTrue(text.contains(reason), "\(name): \(text)")
                if reason == "R8" { XCTAssertNil(LHAUpdater.rewriteReason(reader: reader)) }
                else { XCTAssertEqual(LHAUpdater.rewriteReason(reader: reader), text, name) }
            }
            let after = try ZipP1Support.info(source)
            XCTAssertEqual(before.st_ino, after.st_ino); XCTAssertEqual(before.st_size, after.st_size)
            XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
            XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
            XCTAssertEqual(try ZipUpdateSource(url: source).bytes(at: 0, count: bytes.count), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], name)
        }
    }
    func testSettingsSplitMismatchTrailingAndOtherFormats() throws {
        let root = try TestSupport.directory("lha-routing")
        let source = try LHAUpdateSupport.generated(root)
        let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.lzh")
        func refused(_ url: URL, options: WriterOptions = .init(), reason: String) throws {
            XCTAssertThrowsError(try LHAUpdater.open(url: url, output: output, options: options)) {
                guard case UpdaterRouteError.requiresRewrite(let text) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(text.contains(reason), text)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
        try refused(source, options: .init(additionPlacement: .beginning), reason: "additionPlacement")
        let split = root.appendingPathComponent("source.lzh.001")
        try FileManager.default.copyItem(at: source, to: split)
        try refused(split, reason: "split volume name")
        try LHALayout.$testingKaitoKitMismatch.withValue(true) { try refused(source, reason: "R8") }
        XCTAssertNil(LHAUpdater.rewriteReason(reader: try ArchiveReader.open(url: source)))
        let reset = try LHAUpdater.open(url: source, output: output, options: .init(carriedTarOwnerIDs: .reset))
        try reset.commit(); try FileManager.default.removeItem(at: output)
        let trailer = root.appendingPathComponent("trailer.lzh")
        try (Data(contentsOf: source) + Data(count: 65537)).write(to: trailer)
        try refused(trailer, reason: "L3")
        let zip = root.appendingPathComponent("other.tar")
        let writer = try ArchiveWriter.create(url: zip, format: .tar); try writer.add(data: Data(), as: "one"); try writer.finish()
        XCTAssertThrowsError(try LHAUpdater.open(url: zip, output: output)) {
            guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
    func testUnrepresentableMethodsAndSymlinks() throws {
        let root = try TestSupport.directory("lha-unrepresentable")
        let work = try TestSupport.work(in: root)
        for kind in 0..<2 {
            let source = root.appendingPathComponent("source-\(kind).lzh")
            let h = LHAHeaderBuilder.header(level: 2, name: Data((kind == 0 ? "unsupported" : "link|target").utf8), packed: 0, original: 0, crc: 0,
                                           method: kind == 0 ? "-pm2-" : "-lhd-", extensions: kind == 0 ? [] : [(UInt8(0x50), LHAHeaderBuilder.le(0o120777, 2))])
            try (h + Data([0])).write(to: source)
            XCTAssertThrowsError(try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))) {
                guard case RewriterError.unrepresentable = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
    func testMacBinaryEnvelopeIsStillUnrepresentable() throws {
        let root = try TestSupport.directory("lha-macbinary"), work = try TestSupport.work(in: root)
        var envelope = Data(count: 256)
        envelope[1] = 6
        envelope.replaceSubrange(2..<8, with: Data("member".utf8))
        envelope.replaceSubrange(65..<73, with: Data("BINATEST".utf8))
        envelope[86] = 4
        envelope.replaceSubrange(128..<132, with: Data("data".utf8))
        let header = LHAHeaderBuilder.header(level: 1, name: Data("member".utf8), packed: UInt64(envelope.count), original: UInt64(envelope.count), crc: LHATestSupport.crc(envelope), os: 0x6D)
        let source = root.appendingPathComponent("source.lzh")
        try (header + envelope + Data([0])).write(to: source)
        XCTAssertThrowsError(try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))) {
            guard case RewriterError.unrepresentable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
}
