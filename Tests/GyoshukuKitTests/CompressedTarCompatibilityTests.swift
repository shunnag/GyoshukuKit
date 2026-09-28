import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarCompatibilityTests: XCTestCase {
    func testNewAndOldLayoutsThroughIndependentTools() throws {
        for format in CompressedTarTestSupport.formats {
            for aligned in [false, true] {
                let root = try TestSupport.directory("p3-compat-\(format)-\(aligned)")
                let source = try CompressedTarTestSupport.fixture(root, format, aligned: aligned)
                let output = root.appendingPathComponent("out." + format.testFileExtension)
                _ = try CompressedTarTestSupport.edit(source, format: format, output: output) {
                    try $0.remove(entriesAt: [2]); try $0.rename(entryAt: 0, to: "renamed");
                    try $0.add(data: Data([5]), as: "added", modificationDate: TestSupport.date, permissions: nil)
                }
                try CompressedTarCompatibility.verify(output, format: format)
            }
        }
    }
}
