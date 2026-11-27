import Foundation
import KaitoKit
@testable import GyoshukuKit
import XCTest

final class EditingReaderOptionsTests: XCTestCase {
    func testDefaultPreservesLegacyUnlimitedSizes() {
        let options = EditingReaderOptions.make()
        XCTAssertEqual(options.limits.maxEntrySize, .max)
        XCTAssertEqual(options.limits.maxTotalUncompressedSize, .max)
        XCTAssertNil(WriterOptions().editingReadLimits)
    }

    func testConfiguredLimitsSurviveWriterOptionResolution() {
        let limits = ReadLimits(
            maxEntrySize: 123,
            maxTotalUncompressedSize: 456,
            parallelDecodeMemory: 789
        )
        let options = WriterOptions(editingReadLimits: limits).resolvingCompressionThreads()
        let readerOptions = EditingReaderOptions.make(limits: options.editingReadLimits)
        XCTAssertEqual(readerOptions.limits, limits)
        XCTAssertEqual(readerOptions.appleDoublePolicy, .expose)
    }

    func testEditingInputsHonorExpansionLimitWhenReopened() throws {
        let root = try TestSupport.directory("editing-expansion-limit")
        let payload = Data("archive input for the editing limit check".utf8)
        let editors: [(GyoshukuKit.ArchiveFormat, (URL, URL, WriterOptions) throws -> Void)] = [
            (.tar, { _ = try TarUpdater.open(url: $0, output: $1, options: $2) }),
            (.zip, { _ = try ArchiveUpdater.open(url: $0, output: $1, options: $2) }),
            (.sevenZip, { _ = try SevenZipUpdater.open(url: $0, output: $1, options: $2) }),
            (.lha, { _ = try LHAUpdater.open(url: $0, output: $1, options: $2) }),
            (.zip, { _ = try ArchiveRewriter.open(url: $0, output: $1, format: .zip, options: $2) }),
        ]
        for (format, openEditor) in editors {
            let source = root.appendingPathComponent(UUID().uuidString)
            let output = root.appendingPathComponent(UUID().uuidString)
            let writer = try ArchiveWriter.create(url: source, format: format)
            try writer.add(data: payload, as: "entry")
            try writer.finish()
            var options = WriterOptions()
            options.editingExpansionLimit = ArchiveExpansionLimit(minimumAllowance: UInt64(payload.count), maximumRatio: 0)
            XCTAssertNoThrow(try openEditor(source, output, options))
            options.editingExpansionLimit = ArchiveExpansionLimit(minimumAllowance: UInt64(payload.count - 1), maximumRatio: 0)
            XCTAssertThrowsError(try openEditor(source, output, options)) {
                let limit = KaitoError.limitExceeded("total uncompressed size")
                if let wrapped = $0 as? RewriterError {
                    XCTAssertEqual(wrapped, .invalidArchive(String(describing: limit)))
                } else {
                    XCTAssertEqual($0 as? KaitoError, limit)
                }
            }
        }
    }

    func testTarUpdaterUsesConfiguredLimitsWithoutChangingTheDefault() throws {
        let root = try TestSupport.directory("editing-reader-limits")
        let source = try TarEditTestSupport.fixture(root)
        let legacy = try TarUpdater.open(url: source, output: root.appendingPathComponent("legacy.tar"))
        XCTAssertEqual(legacy.entryNames.count, 6)

        for limits in [
            ReadLimits(maxEntrySize: 16),
            ReadLimits(maxTotalUncompressedSize: 16),
        ] {
            let options = WriterOptions(editingReadLimits: limits)
            XCTAssertThrowsError(try TarUpdater.open(
                url: source,
                output: root.appendingPathComponent("limited-\(UUID().uuidString).tar"),
                options: options
            )) { error in
                guard case .limitExceeded = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }
}
