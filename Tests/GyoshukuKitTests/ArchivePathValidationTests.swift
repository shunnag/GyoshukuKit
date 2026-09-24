import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchivePathValidationTests: XCTestCase {
    private let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]

    func testCombiningMarksDoNotHideInvalidPathBytesOrComponents() throws {
        for format in formats {
            for directory in [false, true] {
                for path in ["../\u{301}escape", "/\u{301}absolute", "a//\u{301}child"] {
                    XCTAssertThrowsError(try ArchiveWriter.normalizedPath(path, directory: directory, format: format), path)
                }
                for path in ["bad\\\u{301}name", "bad:\u{301}name"] {
                    if format.isTar {
                        XCTAssertEqual(try ArchiveWriter.normalizedPath(path, directory: directory, format: format),
                                       path + (directory ? "/" : ""))
                    } else {
                        XCTAssertThrowsError(try ArchiveWriter.normalizedPath(path, directory: directory, format: format), path)
                    }
                }
            }
            XCTAssertEqual(try ArchiveWriter.normalizedPath("parent/\u{301}child", directory: false, format: format),
                           "parent/\u{301}child")
        }
    }

    func testAllFormatsKeepCommonPathRestrictionsAndUTF8ByteLimit() throws {
        let longestBody = String(repeating: "é", count: 32_767)
        for format in formats {
            for directory in [false, true] {
                for path in ["", "/", "/absolute", ".", "..", "a/./b", "a/../b", "a//b", "nul\0name",
                             longestBody + "aa"] {
                    XCTAssertThrowsError(try ArchiveWriter.normalizedPath(path, directory: directory, format: format)) {
                        XCTAssertEqual($0 as? WriterError, .invalidPath(path))
                    }
                }
            }
            XCTAssertEqual(try ArchiveWriter.normalizedPath(longestBody + "a", directory: false, format: format),
                           longestBody + "a")
            XCTAssertEqual(try ArchiveWriter.normalizedPath(longestBody, directory: true, format: format),
                           longestBody + "/")
            XCTAssertThrowsError(try ArchiveWriter.normalizedPath(longestBody + "a", directory: true, format: format))
            XCTAssertThrowsError(try ArchiveWriter.normalizedPath("file/", directory: false, format: format))
        }
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
