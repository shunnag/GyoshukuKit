import Foundation
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipInPlaceRenameTests: XCTestCase {
    func testOneAndThousandRenamesOnlyWriteHeaderPatches() throws {
        let directory = try TestSupport.directory("p1-in-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        for count in [1, 1000] {
            let source = try ZipP1Support.fixture(directory, name: "source-\(count).zip", count: count, payloadSize: 32)
            let reader = try ArchiveReader.open(url: source)
            let input = try ZipUpdateSource(url: source), layout = try ZipUpdateLayout(source: input)
            let validated = try ZipCentralDirectory.validate(source: input, reader: reader, centralOffset: layout.centralOffset, centralSize: layout.centralSize)
            let operations = (0..<count).map { ZipP1Support.Operation.rename($0, String(format: "other-%06d.txt", $0)) }
            let output = directory.appendingPathComponent("output-\(count).zip")
            let oracle = directory.appendingPathComponent("oracle-\(count).zip")
            try ZipP1Support.legacy(source: source, output: oracle, operations: operations)
            let updater = try ArchiveUpdater.open(url: source, output: output)
            try ZipP1Support.mutate(updater, operations)
            let events = ZipIOEvents()
            try ZipCopyEngine.$writeObserver.withValue(events.write) { try updater.commit() }
            XCTAssertEqual(updater.lastCommitStrategy, .inPlacePatch)
            let ranges = validated.records.flatMap { record -> [Range<UInt64>] in
                [record.layout.recordRange.lowerBound..<record.layout.payloadRange.lowerBound,
                 (layout.centralOffset + UInt64(record.centralRange.lowerBound))..<(layout.centralOffset + UInt64(record.centralRange.upperBound))]
            }
            for event in events.events {
                XCTAssertTrue(ranges.contains { $0.lowerBound <= event.offset && event.offset + UInt64(event.count) <= $0.upperBound })
            }
            XCTAssertEqual(events.events.count, count * 2)
            try XCTAssertFilesEqual(output, oracle)
        }
    }

    func testNoncanonicalEndsGapsAndCentralNameLengthUseGeneralPath() throws {
        let directory = try TestSupport.directory("p1-in-place-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        for variant in ["redundant", "gap", "tailgap", "cdname"] {
            let source = try ZipP1Corpus.crafted(directory, variant: variant)
            try ZipP1Support.compare(source, operations: [.rename(0, "newer.txt")], label: variant, expectedStrategy: .rebuild)
        }
        for variant in ["sentinel-end", "extended-end", "madeby-end"] {
            let url = try ZipP1Corpus.crafted(directory, variant: variant)
            var bytes = try Data(contentsOf: url)
            let end = bytes.count - 22, central = UInt64(bytes.zip32(end + 16)), size = UInt64(bytes.zip32(end + 12))
            bytes.removeSubrange(end..<bytes.count)
            var ending = try ZipRecords.end(count: 65_535, centralSize: size, centralOffset: central)
            ending.zipSet(UInt64(5), at: 24); ending.zipSet(UInt64(5), at: 32)
            if variant != "sentinel-end" { ending.zipSet(UInt16(5), at: 76 + 8); ending.zipSet(UInt16(5), at: 76 + 10) }
            if variant == "madeby-end" { ending.zipSet(UInt16(20), at: 12) }
            if variant == "extended-end" {
                ending.zipSet(UInt64(48), at: 4)
                ending.insert(contentsOf: [0, 0, 0, 0], at: 56)
            }
            bytes.append(ending)
            try bytes.write(to: url)
            try ZipP1Support.compare(url, operations: [.rename(0, "newer.txt")], label: variant, expectedStrategy: .rebuild)
        }
        let force = try ZipP1Corpus.forceZIP64(directory)
        try ZipP1Support.compare(force, operations: [.rename(0, "newer.txt")], label: "force64-patch", expectedStrategy: .inPlacePatch)
        let source = try ZipP1Support.fixture(directory)
        try ZipP1Support.compare(source, operations: [.rename(0, "newer.txt"), .add("added", Data())],
                                label: "with-add", expectedStrategy: .rebuildThenAppend)
    }
}
