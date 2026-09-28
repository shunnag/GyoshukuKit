import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterPlacementTests: XCTestCase {
    func testBothPlacementsInAllFormatsAndDeferredOutput() throws {
        let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]
        for format in formats {
            for placement in [AdditionPlacement.end, .beginning] {
                let root = try TestSupport.directory("p2-placement-\(format)-\(placement)")
                let source = try TarEditTestSupport.fixture(root, count: 3)
                let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output." + format.testFileExtension)
                let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format,
                                                       options: .init(additionPlacement: placement))
                try rewriter.remove(entriesAt: [1])
                try rewriter.rename(entryAt: 2, to: "renamed")
                try rewriter.add(data: Data([9, 8]), as: "added", modificationDate: TestSupport.date)
                try rewriter.addDirectory("dir", modificationDate: TestSupport.date, ownerIDs: nil)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, placement == .end)
                var carried: [Int] = []
                try rewriter.commit { completed, total in XCTAssertEqual(total, 2); carried.append(completed) }
                XCTAssertEqual(carried, [1, 2])
                let reader = try ArchiveReader.open(url: output)
                XCTAssertEqual(reader.entries.map(\.name), placement == .end
                    ? ["file-000000", "renamed", "added", "dir/"] : ["added", "dir/", "file-000000", "renamed"])
                let directory = try XCTUnwrap(reader.entries.first { $0.kind == .directory })
                XCTAssertEqual(directory.modificationDate, TestSupport.date)
                XCTAssertEqual(directory.posixPermissions, 0o755)
                XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "added" })), Data([9, 8]))
            }
        }
    }

    func testQueuedSourceIdentityAndImmediateReservationFailures() throws {
        for mutation in 0..<5 {
            let root = try TestSupport.directory("p2-queued-source-\(mutation)")
            let source = try TarEditTestSupport.fixture(root)
            let before = try Data(contentsOf: source)
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("out.tar")
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
