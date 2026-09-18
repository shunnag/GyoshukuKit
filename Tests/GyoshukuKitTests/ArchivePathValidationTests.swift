import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchivePathValidationTests: XCTestCase {
    func testCombiningMarksDoNotHideInvalidPathBytesOrComponents() throws {
        for directory in [false, true] {
            for path in ["../\u{301}escape", "/\u{301}absolute", "a//\u{301}child", "bad\\\u{301}name", "bad:\u{301}name"] {
                XCTAssertThrowsError(try ArchiveWriter.normalizedPath(path, directory: directory), path)
            }
        }
        XCTAssertEqual(try ArchiveWriter.normalizedPath("parent/\u{301}child", directory: false), "parent/\u{301}child")
    }

    func testCombiningMarkChildConflictsWithAFileParentInEitherOrder() throws {
        let root = try ZipTestSupport.directory("combining-path-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        for parentFirst in [false, true] {
            let archive = root.appendingPathComponent("writer-\(parentFirst).zip")
            let writer = try ArchiveWriter.create(url: archive)
            try writer.add(data: Data(), as: parentFirst ? "parent" : "parent/\u{301}child")
            XCTAssertThrowsError(try writer.add(data: Data(), as: parentFirst ? "parent/\u{301}child" : "parent")) {
                guard case WriterError.invalidPath = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            let archive = root.appendingPathComponent("editor-\(format)")
            let writer = try ArchiveWriter.create(url: archive, format: format)
            try writer.add(data: Data("child".utf8), as: "parent/\u{301}child")
            try writer.add(data: Data("other".utf8), as: "other")
            try writer.finish()
            let editor: any ArchiveEditing = format == .zip
                ? try ArchiveUpdater.open(url: archive) : try ArchiveRewriter.open(url: archive, format: format)
            XCTAssertThrowsError(try editor.rename(entryAt: 1, to: "parent")) {
                guard case WriterError.invalidPath = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.name), ["parent/\u{301}child", "other"])
        }
    }
}
