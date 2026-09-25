import Foundation
@_spi(ZipRawLayout) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipCentralFastPathTests: XCTestCase {
    func testCanonicalClassificationAndFastBytes() throws {
        let directory = try ZipTestSupport.directory("p1-central-fast")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try [ZipP1Support.fixture(directory), ZipP1Corpus.forceZIP64(directory)]
            + ["redundant", "sentinel", "marker", "padding", "unicode"].map { try ZipP1Corpus.crafted(directory, variant: $0) }
        for url in sources {
            let source = try ZipUpdateSource(url: url)
            let layout = try ZipUpdateLayout(source: source)
            let reader = try ArchiveReader.open(source: source, options: ArchiveUpdater.readerOptions)
            let validated = try ZipCentralDirectory.validate(source: source, reader: reader,
                centralOffset: layout.centralOffset, centralSize: layout.centralSize)
            for (index, record) in validated.records.enumerated() {
                let spi = try XCTUnwrap(reader.zipRawRecordLayout(at: index))
                let header = try ZipRebuild.CentralHeader(bytes: validated.bytes, range: record.centralRange)
                XCTAssertEqual(spi.centralHasZIP64Extra, ZipRebuild.extraFields(header.extra).contains { $0.id == 1 })
                XCTAssertEqual(record.canonical, !spi.centralHasZIP64Extra)
                if record.canonical {
                    for offset in [record.layout.recordRange.lowerBound, 0, 0xFFFFFFFE] {
                        var fast = validated.bytes.subdata(in: record.centralRange)
                        fast.zipSet(UInt32(offset), at: 42)
                        XCTAssertEqual(fast, try header.rebuilt(offset: offset, size: reader.entries[index].uncompressedSize!,
                            compressedSize: reader.entries[index].compressedSize!, name: nil))
                        XCTAssertTrue(record.usesFastPath(offset: offset, renamed: false, marker: false))
                    }
                }
                XCTAssertFalse(record.usesFastPath(offset: ZipRecords.limit, renamed: false, marker: false))
                XCTAssertFalse(record.usesFastPath(offset: 0, renamed: true, marker: false))
                XCTAssertFalse(record.usesFastPath(offset: 0, renamed: false, marker: true))
            }
        }
    }

    func testValidateReadsCentralOnceAndEnforcesLimit() throws {
        let directory = try ZipTestSupport.directory("p1-central-io")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ZipP1Support.fixture(directory, count: 100, payloadSize: 32)
        let source = try ZipUpdateSource(url: url), layout = try ZipUpdateLayout(source: source)
        let reader = try ArchiveReader.open(source: source, options: ArchiveUpdater.readerOptions)
        let events = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(events.read) {
            try ZipCentralDirectory.validate(source: source, reader: reader,
                centralOffset: layout.centralOffset, centralSize: layout.centralSize)
        }
        let central = events.events.filter { $0.offset >= layout.centralOffset }
        XCTAssertEqual(central.count, 1)
        XCTAssertEqual(central.first?.offset, layout.centralOffset)
        XCTAssertEqual(central.first?.count, Int(layout.centralSize))
        XCTAssertFalse(central.contains { $0.count == 46 })
        XCTAssertThrowsError(try ZipCentralDirectory.validate(source: source, reader: reader,
            centralOffset: layout.centralOffset, centralSize: layout.centralSize, maximumCentralSize: layout.centralSize - 1)) {
            guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
        }
        let openEvents = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(openEvents.read) { _ = try ArchiveUpdater.open(url: url) }
        XCTAssertFalse(openEvents.events.contains { $0.offset >= layout.centralOffset && $0.offset < layout.centralOffset + layout.centralSize && $0.count == 46 })
    }
}
