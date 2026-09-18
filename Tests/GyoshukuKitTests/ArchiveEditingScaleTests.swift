import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveEditingScaleTests: XCTestCase {
    func testBulkRenamesAfterAddingPreserveEveryPayloadAndReleaseOldPaths() throws {
        let root = try ZipTestSupport.directory("editing-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            for count in [1_000, 2_000, 4_000] {
                let archive = root.appendingPathComponent("\(format)-\(count)")
                let writer = try ArchiveWriter.create(url: archive, format: format, options: .init(compressionMethod: .stored))
                for index in 0..<count {
                    try writer.add(data: Data("payload-\(index)".utf8), as: "source/file\(index)")
                }
                try writer.finish()
                let editor: any ArchiveEditing = format == .zip
                    ? try ArchiveUpdater.open(url: archive)
                    : try ArchiveRewriter.open(url: archive, format: format)
                try editor.add(data: Data("added".utf8), as: "added", modificationDate: nil, permissions: nil)
                let start = ContinuousClock.now
                for index in 0..<count {
                    try editor.rename(entryAt: index, to: "renamed/file\(index)")
                    if index == count / 2 {
                        try editor.add(data: Data("replacement".utf8), as: "source/file0",
                                       modificationDate: nil, permissions: nil)
                    }
                }
                let elapsed = start.duration(to: .now)
                print("Edit reservation benchmark: \(format), \(count) entries, \(elapsed)")
                try editor.commit()
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.count, count + 2)
                let contents = try Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.name, try reader.read($0)) })
                XCTAssertEqual(contents["added"], Data("added".utf8))
                XCTAssertEqual(contents["source/file0"], Data("replacement".utf8))
                for index in 0..<count {
                    XCTAssertEqual(contents["renamed/file\(index)"], Data("payload-\(index)".utf8))
                }
                if ProcessInfo.processInfo.environment["CI"] == nil {
                    XCTAssertLessThan(elapsed, .seconds(2))
                }
            }
        }
    }
}
