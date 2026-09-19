import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterCollisionTests: XCTestCase {
    private func fixture(_ names: [String], directoryIndices: Set<Int> = []) throws -> URL {
        let directory = try ZipTestSupport.directory("rewriter-carried-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.zip")
        // Independent zipfile fixture: the product writer deliberately cannot create duplicate names.
        let script = #"""
        import sys,zipfile,warnings
        warnings.simplefilter('ignore', UserWarning)
        directories=set(map(int,filter(None,sys.argv[2].split(','))))
        with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_STORED) as z:
            for i,name in enumerate(sys.argv[3:]):
                info=zipfile.ZipInfo(name,(2023,11,14,22,13,20)); info.create_system=3
                info.external_attr=((0o40755 if i in directories else 0o100644)<<16)|(0x10 if i in directories else 0)
                z.writestr(info,b'' if i in directories else ('payload-%d'%i).encode())
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path,
            directoryIndices.sorted().map(String.init).joined(separator: ",")] + names,
            in: directory, log: "create")
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.count, names.count)
        return url
    }

    private func assertRefused(_ url: URL, entry: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try Data(contentsOf: url)
        let directory = url.deletingLastPathComponent()
        let siblings = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        var accepted: ArchiveRewriter?
        XCTAssertThrowsError(accepted = try ArchiveRewriter.open(url: url, output: nil, format: .zip),
                             "carried-name collisions must be refused at open", file: file, line: line) {
            guard case let RewriterError.unrepresentable(name, reason) = $0 else {
                return XCTFail("expected unrepresentable, got \($0)", file: file, line: line)
            }
            XCTAssertEqual(name, entry, file: file, line: line)
            XCTAssertTrue(reason.contains("衝突"), reason, file: file, line: line)
            ZipTestSupport.report("G6 unrepresentable: \(name): \(reason)")
        }
        if let accepted {
            // Red-run evidence: the old implementation carries the first entry before discovering the collision.
            var carried = 0
            XCTAssertThrowsError(try accepted.commit { done, _ in carried = done }) {
                ZipTestSupport.report("G6 RED late collision after \(carried) carried entries: \($0)")
                XCTAssertTrue($0 is WriterError)
            }
            XCTAssertGreaterThan(carried, 0, "red-run fixture must reach a partial write", file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), siblings, file: file, line: line)
    }

    func testDuplicateCarriedNamesAreRefusedAtOpen() throws {
        try assertRefused(fixture(["a.txt", "a.txt"]), entry: "a.txt")
    }

    func testCanonicallyEquivalentCarriedNamesAreRefusedAtOpen() throws {
        try assertRefused(fixture(["caf\u{e9}.txt", "cafe\u{301}.txt"]), entry: "cafe\u{301}.txt")
    }

    func testDirectorySlashNormalizationCollisionsAreRefusedAtOpen() throws {
        try assertRefused(fixture(["folder", "folder/"], directoryIndices: [0, 1]), entry: "folder/")
    }

    func testCarriedFileAndChildCollisionsAreRefusedInEitherOrder() throws {
        for names in [["parent", "parent/child"], ["parent/child", "parent"]] {
            try assertRefused(fixture(names), entry: names[1])
        }
    }

    func testExplicitDirectoryAfterChildAndOmittedRootsRemainRepresentable() throws {
        let url = try fixture(["./", ".", "folder/child", "folder/"], directoryIndices: [0, 1, 3])
        let rewriter = try ArchiveRewriter.open(url: url, output: nil, format: .zip)
        try rewriter.commit()
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), ["folder/child", "folder/"])
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload-2".utf8))
    }
}
