import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class EmptyArchiveTests: XCTestCase {
    private let formats: [(GyoshukuKit.ArchiveFormat, String, KaitoKit.ArchiveFormat)] = [
        (.zip, "zip", .zip), (.tar, "tar", .tar), (.tarGzip, "tar.gz", .tar),
        (.tarBzip2, "tar.bz2", .tar), (.tarXZ, "tar.xz", .tar),
        (.sevenZip, "7z", .sevenZip), (.lha, "lzh", .lha)
    ]

    func testEveryWriterCanFinishWithoutMembersAndReopen() throws {
        for (format, suffix, expected) in formats {
            let directory = try ZipTestSupport.directory("empty-writer-" + suffix)
            let url = directory.appendingPathComponent("empty." + suffix)
            let writer = try ArchiveWriter.create(url: url, format: format)
            try writer.finish()
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, expected)
            XCTAssertTrue(reader.entries.isEmpty)
            XCTAssertTrue(try reader.reopen().entries.isEmpty)
            if format == .lha {
                XCTAssertEqual(try Data(contentsOf: url), Data([0]))
                LHATestSupport.clean(try LHATestSupport.run(LHATestSupport.lhasa, ["l", url.path],
                    in: directory, log: "empty-lha-list"))
                LHATestSupport.clean(try LHATestSupport.run(LHATestSupport.lhasa, ["t", url.path],
                    in: directory, log: "empty-lha-test"))
            }
        }
    }

    func testEveryRewriterCanRemoveAllMembersAndAddAgain() throws {
        for (format, suffix, expected) in formats {
            let directory = try ZipTestSupport.directory("empty-rewriter-" + suffix)
            let url = directory.appendingPathComponent("archive." + suffix)
            let writer = try ArchiveWriter.create(url: url, format: format)
            try writer.add(data: Data("old".utf8), as: "old.txt")
            try writer.finish()
            let remove = try ArchiveRewriter.open(url: url, format: format)
            try remove.remove(entriesAt: [0])
            try remove.commit()
            let empty = try ArchiveReader.open(url: url)
            XCTAssertEqual(empty.format, expected)
            XCTAssertTrue(empty.entries.isEmpty)
            let append = try ArchiveRewriter.open(url: url, format: format)
            try append.add(data: Data("new".utf8), as: "new.txt")
            try append.commit()
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.entries.map(\.name), ["new.txt"])
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("new".utf8))
        }
    }
}
