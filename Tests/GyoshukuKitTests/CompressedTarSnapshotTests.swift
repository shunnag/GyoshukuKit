import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class CompressedTarSnapshotTests: XCTestCase {
    func testMapsSurviveShortReadsStagingAndReopen() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.directory("p3-snapshot-\(format)")
            let source = try CompressedTarTestSupport.fixture(root, format, large: false)
            let baseline = try XCTUnwrap(CompressedTarTestSupport.open(source).tarEditingSnapshot())
            let expected = try XCTUnwrap(baseline.chunkMap, "\(format): \(String(describing: baseline.chunkMapUnavailableReason))")
            XCTAssertFalse(expected.chunks.isEmpty, "\(format)")
            for disk in [false, true] {
                for maximumRead in [1, 7, 4096, 262144] {
                    var options = CompressedTarTestSupport.readerOptions
                    if disk { options.limits.inMemorySingleFileLimit = 0 }
                    let short = ShortReadSource(source: try FileByteSource(url: source), maximumRead: maximumRead)
                    let reader = try ArchiveReader.open(source: short, sourceURL: source, options: options)
                    let snapshot = try XCTUnwrap(reader.tarEditingSnapshot())
                    let context = "\(format), disk=\(disk), maximumRead=\(maximumRead), chunkMapUnavailableReason=\(String(describing: snapshot.chunkMapUnavailableReason))"
                    XCTAssertEqual(snapshot.image is FileByteSource, disk, context)
                    XCTAssertEqual(snapshot.chunkMap, expected, context)
                    XCTAssertNil(snapshot.chunkMapUnavailableReason, context)
                    try CompressedTarTestSupport.imagesEqual(snapshot.image, baseline.image)
                    let reopened = try reader.reopen()
                    let again = try XCTUnwrap(reopened.tarEditingSnapshot(), context)
                    XCTAssertEqual(again.chunkMap, snapshot.chunkMap, context)
                    XCTAssertEqual(again.chunkMapUnavailableReason, snapshot.chunkMapUnavailableReason, context)
                    XCTAssertTrue(again.image as AnyObject === snapshot.image as AnyObject, context)
                }
            }
            // Even an empty GK tar contains its terminator, so its map is nonempty.
            let empty = root.appendingPathComponent("empty." + format.testFileExtension)
            let writer = try ArchiveWriter.create(url: empty, format: format)
            try writer.finish()
            let snapshot = try XCTUnwrap(CompressedTarTestSupport.open(empty).tarEditingSnapshot())
            let context = "empty \(format), chunkMapUnavailableReason=\(String(describing: snapshot.chunkMapUnavailableReason))"
            XCTAssertGreaterThan(snapshot.image.length, 0, context)
            XCTAssertFalse(try XCTUnwrap(snapshot.chunkMap, context).chunks.isEmpty, context)
        }
    }
}

private struct ShortReadSource: ByteSource {
    let source: FileByteSource
    let maximumRead: Int
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try source.read(into: .init(rebasing: buffer[..<min(buffer.count, maximumRead)]), at: offset)
    }
}
