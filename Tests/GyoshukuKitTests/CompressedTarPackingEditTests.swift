import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarPackingEditTests: XCTestCase {
    private let limits = TarChunkLimits(packing: 4 * 1024 * 1024, piece: 16 * 1024 * 1024)

    func testMediumRenameDeleteAndPackedDeletePreserveBodies() throws {
        let root = try ZipTestSupport.directory("p14-packing-edits")
        let source = try CompressedTarTestSupport.packingFixture(root)
        let reader = try CompressedTarTestSupport.open(source)
        let medium = try XCTUnwrap(reader.entries.first { $0.name == "medium" })
        let packed = try XCTUnwrap(reader.entries.first { $0.name == "before-6" })
        let snapshot = try XCTUnwrap(reader.tarEditingSnapshot())
        let chunks = try XCTUnwrap(snapshot.chunkMap).chunks
        let body = try XCTUnwrap(chunks.first { $0.imageRange.byteLength > UInt64(limits.packing) })
        let renamed = try CompressedTarTestSupport.edit(source, format: .tarXZ, output: root.appendingPathComponent("rename.tar.xz")) {
            try $0.rename(entryAt: medium.index, to: "renamed-medium")
        }
        XCTAssertLessThanOrEqual(renamed.reencodedImageBytes, UInt64(512 + 2 * limits.packing / 16))
        XCTAssertTrue(renamed.segments.contains {
            if case .reused(_, let base) = $0 { return base.lowerBound <= body.compressedRange.lowerBound && base.upperBound >= body.compressedRange.upperBound }
            return false
        })
        let deleted = try CompressedTarTestSupport.edit(source, format: .tarXZ, output: root.appendingPathComponent("delete.tar.xz")) {
            try $0.remove(entriesAt: [medium.index])
        }
        XCTAssertLessThanOrEqual(deleted.reencodedOldImageBytes, UInt64(2 * limits.packing / 16))
        XCTAssertFalse(deleted.segments.contains {
            if case .reused(_, let base) = $0 { return base.overlaps(body.compressedRange) }
            return false
        })
        let small = try CompressedTarTestSupport.edit(source, format: .tarXZ, output: root.appendingPathComponent("packed-delete.tar.xz")) {
            try $0.remove(entriesAt: [packed.index])
        }
        XCTAssertLessThanOrEqual(small.reencodedImageBytes, UInt64(limits.packing + 2 * limits.packing / 16))
    }

    func testOldPackingEditsRepartitionEncodedBridges() throws {
        let root = try ZipTestSupport.directory("p14-old-packing")
        let source = try CompressedTarTestSupport.packingFixture(root, oldPacking: true, bodyExcess: 129)
        let reader = try CompressedTarTestSupport.open(source)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "medium" })
        for rename in [false, true] {
            let output = root.appendingPathComponent("\(rename).tar.xz")
            let result = try CompressedTarTestSupport.edit(source, format: .tarXZ, output: output) {
                if rename { try $0.rename(entryAt: entry.index, to: "renamed-medium") }
                else { try $0.remove(entriesAt: [entry.index]) }
            }
            try verifyBridges(output, result: result)
        }
    }

    func testOldFolderRenameFullEncodeSeparatesEveryHeaderAndBody() throws {
        let root = try ZipTestSupport.directory("p14-old-folder")
        let raw = root.appendingPathComponent("folder.tar"), source = root.appendingPathComponent("old.tar.xz")
        let writer = try ArchiveWriter.create(url: raw, format: .tar)
        try writer.addDirectory("folder/", modificationDate: ZipTestSupport.date, ownerIDs: nil)
        let size = limits.packing + 100_000
        for index in 0..<3 {
            try writer.add(data: Data(repeating: UInt8(index), count: size), as: "folder/file-\(index)", modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        try CompressedTarTestSupport.compress(raw, to: source, format: .tarXZ, packingSize: limits.piece)
        let output = root.appendingPathComponent("renamed.tar.xz")
        let result = try CompressedTarTestSupport.edit(source, format: .tarXZ, output: output) {
            try $0.rename(entryAt: 0, to: "rename/")
        }
        guard case .fullEncode = result.strategy else { return XCTFail("expected fullEncode: \(result.strategy)") }
        let map = try XCTUnwrap(CompressedTarTestSupport.open(output).tarEditingSnapshot()?.chunkMap)
        let padded = UInt64((size + 511) / 512 * 512)
        XCTAssertEqual(map.chunks.dropLast().map { $0.imageRange.byteLength }, [512, 512, padded, 512, padded, 512, padded])
        try verifyBridges(output, result: result)
    }

    func testBridgeStartingInsideLargeBodyUsesRemainingMemberLength() {
        let end = UInt64(2 * limits.piece + 512)
        let image = TarImageSource(spans: [], length: end + 1024,
            members: [.init(start: 0, data: 512, end: end)], terminalStart: end)
        let start = UInt64(limits.piece + 1024)
        XCTAssertEqual(CompressedTarSplicePlan.cuts(start..<image.length, image: image, limits: limits),
                       [start..<end, end..<image.length])
    }

    private func verifyBridges(_ output: URL, result: CompressedTarCommitResult) throws {
        let decoded = try TarChunkLayoutTestSupport.decode(output, format: .tarXZ)
        let members = try TarChunkLayoutTestSupport.members(in: decoded.raw)
        let map = try XCTUnwrap(CompressedTarTestSupport.open(output).tarEditingSnapshot()?.chunkMap)
        for segment in result.segments {
            guard case .encoded(let range) = segment else { continue }
            let chunks = map.chunks.filter { range.contains($0.compressedRange.lowerBound) }
            guard let first = chunks.first, let last = chunks.last else { continue }
            let start = Int(first.imageRange.lowerBound), end = Int(last.imageRange.upperBound)
            let clipped: [TarChunkLayoutTestSupport.Member] = members.filter { $0.end > start && $0.groupStart < end }.map {
                (max(start, $0.groupStart) - start, min(end, max(start, $0.dataStart)) - start, min(end, $0.end) - start)
            }
            let expected = TarChunkLayoutTestSupport.ranges(members: clipped, total: end - start, limits: limits)
            XCTAssertEqual(chunks.map { Int($0.imageRange.byteLength) }, expected.map(\.count))
        }
    }
}
