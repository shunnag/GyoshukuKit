import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipUpdateProbeTests: XCTestCase {
    private func archive(_ label: String, count: Int = 3, longNames: Bool = false) throws -> URL {
        let directory = try ZipTestSupport.directory("probe-" + label)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored))
        // Same writer/entry-loop fixture as ArchiveEditingScaleTests; padding makes the CD multi-MiB.
        let prefix = longNames ? String(repeating: String(repeating: "a", count: 200) + "/", count: 4) : ""
        for index in 0..<count {
            try writer.add(data: Data(), as: prefix + "entry-\(index)", modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        return url
    }

    private func assertAccepted(_ url: URL, count: UInt64, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: url)
        let probe = try ArchiveUpdater.probe(url: url)
        XCTAssertEqual(probe.entryCount, count, file: file, line: line)
        XCTAssertEqual(probe.entryCount, UInt64(try ArchiveUpdater.open(url: url).entryNames.count), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), before, file: file, line: line)
    }

    private func assertRefused(_ url: URL, error expected: UpdaterError,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ArchiveUpdater.probe(url: url), file: file, line: line) {
            XCTAssertEqual($0 as? UpdaterError, expected, file: file, line: line)
        }
        XCTAssertThrowsError(try ArchiveUpdater.open(url: url), file: file, line: line) {
            XCTAssertEqual($0 as? UpdaterError, expected, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: url), before, file: file, line: line)
    }

    // Independent, forced ZIP64 end records, including canonical count-zero archives.
    private func zip64(_ data: Data) -> Data {
        let bytes = ZipBytes(data: data)
        var result = Data(data.prefix(bytes.end))
        result.le(UInt32(0x06064B50)); result.le(UInt64(44))
        result.le(UInt16(45)); result.le(UInt16(45))
        result.le(UInt32(0)); result.le(UInt32(0))
        result.le(UInt64(bytes.u16(bytes.end + 10))); result.le(UInt64(bytes.u16(bytes.end + 10)))
        result.le(UInt64(bytes.u32(bytes.end + 12))); result.le(UInt64(bytes.central))
        result.le(UInt32(0x07064B50)); result.le(UInt32(0))
        result.le(UInt64(bytes.end)); result.le(UInt32(1))
        var end = Data(data.suffix(22))
        end.zipSet(UInt16.max, at: 8); end.zipSet(UInt16.max, at: 10)
        end.zipSet(UInt32.max, at: 12); end.zipSet(UInt32.max, at: 16)
        result.append(end)
        return result
    }

    func testProbeAcceptsNormalZIP() throws {
        try assertAccepted(archive("normal"), count: 3)
    }

    func testProbeAcceptsCanonicalEmptyZIPWithMaximumComment() throws {
        let url = try archive("empty", count: 0)
        var data = try Data(contentsOf: url)
        data.zipSet(UInt16.max, at: 20)
        data.append(Data(repeating: 0x61, count: Int(UInt16.max)))
        try data.write(to: url)
        try assertAccepted(url, count: 0)
    }

    func testProbeAcceptsZIP64AndCanonicalEmptyZIP64() throws {
        for count in [0, 3] {
            let url = try archive("zip64-\(count)", count: count)
            try zip64(Data(contentsOf: url)).write(to: url)
            try assertAccepted(url, count: UInt64(count))
        }
    }

    func testProbeRefusesSFXPrefixLikeOpen() throws {
        let url = try archive("sfx")
        let data = Data("MZ".utf8) + Data(repeating: 0, count: 126) + (try Data(contentsOf: url))
        try data.write(to: url)
        try assertRefused(url, error: .editingRefused(gatekeeper: .sfxPrefix, reason: UpdateGatekeeper.sfxPrefix.reason))
    }

    func testProbeRefusesTrailingDataLikeOpen() throws {
        let url = try archive("trailing")
        try (Data(contentsOf: url) + Data("trailing data".utf8)).write(to: url)
        try assertRefused(url, error: .editingRefused(gatekeeper: .trailingData, reason: UpdateGatekeeper.trailingData.reason))
    }

    func testProbeRefusesBadCentralDirectoryOffsetLikeOpen() throws {
        let url = try archive("bad-offset")
        let original = try Data(contentsOf: url)
        for offset: UInt32 in [0, UInt32(original.count)] {
            var data = original
            data.zipSet(offset, at: data.count - 6)
            try data.write(to: url)
            try assertRefused(url, error: .editingRefused(gatekeeper: .centralDirectoryOffset,
                                                        reason: UpdateGatekeeper.centralDirectoryOffset.reason))
        }
    }

    func testProbeRefusesSplitZIPAndZIP64LikeOpen() throws {
        let url = try archive("split")
        let original = try Data(contentsOf: url)
        var split = original
        split.zipSet(UInt16(1), at: split.count - 18)
        try split.write(to: url)
        try assertRefused(url, error: .invalidArchive("分割 ZIP は編集できません"))
        var wide = zip64(original)
        wide.zipSet(UInt32(2), at: wide.count - 26)
        try wide.write(to: url)
        try assertRefused(url, error: .invalidArchive("ZIP64 locator が単一 volume ではありません"))
    }

    func testProbeRefusesNativeSplitZIPFinalVolumeLikeOpen() throws {
        let url = try archive("split-final-volume")
        let original = try Data(contentsOf: url)
        // 最終巻が CD から始まり、先頭 local header がない構造を作る。
        let finalVolume = Data(original[ZipBytes(data: original).central...])
        XCTAssertEqual(finalVolume.zip32(0), 0x02014B50)
        let end = finalVolume.count - 22
        let fields: [(UInt16, UInt16, UInt16)] = [(2, 0, 3), (0, 2, 3), (0, 0, 2)]
        for (disk, centralDisk, entriesOnDisk) in fields {
            var data = finalVolume
            data.zipSet(disk, at: end + 4)
            data.zipSet(centralDisk, at: end + 6)
            data.zipSet(entriesOnDisk, at: end + 8)
            data.zipSet(UInt32(0), at: end + 16)
            try data.write(to: url)
            try assertRefused(url, error: .invalidArchive("分割 ZIP は編集できません"))
        }
    }

    func testProbeRefusesSplitZIPBeforeTrailingDataLikeOpen() throws {
        let url = try archive("split-trailing")
        var data = try Data(contentsOf: url)
        data.zipSet(UInt16(1), at: data.count - 18)
        data.append(Data("trailing data".utf8))
        try data.write(to: url)
        try assertRefused(url, error: .invalidArchive("分割 ZIP は編集できません"))
    }

    func testProbeRefusesMalformedEndRecordsLikeOpen() throws {
        let url = try archive("malformed", count: 0)
        var noncanonical = try Data(contentsOf: url)
        noncanonical.zipSet(UInt32(1), at: 16)
        try noncanonical.write(to: url)
        try assertRefused(url, error: .invalidArchive("空 ZIP の終端が矛盾しています"))
        try Data(repeating: 0, count: 100).write(to: url)
        try assertRefused(url, error: .invalidArchive("EOCD がありません"))
    }

    func testProbeReadsOnlyBoundedTailWithMultiMiBCentralDirectory() throws {
        let url = try archive("scale", count: 4_000, longNames: true)
        var data = try Data(contentsOf: url)
        data.zipSet(UInt16.max, at: data.count - 2)
        data.append(Data(repeating: 0x61, count: Int(UInt16.max)))
        try data.write(to: url)
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        XCTAssertGreaterThan(layout.centralSize, 3 * 1024 * 1024)
        let counter = ZipReadCounter()
        let probe = try counter.measure { try ArchiveUpdater.probe(url: url) }
        XCTAssertEqual(probe.entryCount, 4_000)
        ZipTestSupport.report("G2 probe entries=\(probe.entryCount) central bytes=\(layout.centralSize) comment bytes=\(layout.comment.count) source bytes=\(counter.byteCount)")
        XCTAssertLessThan(counter.byteCount, UInt64(2 * 1024 * 1024 + layout.comment.count),
                          "probe must not parse the multi-MiB central directory")
        // The bounded EOCD search can overlap the CD tail; outside it only two signatures are read.
        let tailStart = source.length - UInt64(22 + 65_535 + 1_048_576)
        XCTAssertTrue(counter.ranges.allSatisfy {
            $0 == 0..<4 || $0 == layout.centralOffset..<(layout.centralOffset + 4)
                || ($0.lowerBound >= tailStart && $0.upperBound <= source.length)
        }, "probe must read only the bounded tail and the prefix/CD signatures")
        XCTAssertEqual(probe.entryCount, UInt64(try ArchiveUpdater.open(url: url).entryNames.count))
    }

    func testProbeLeavesEntryValidationToCallersReader() throws {
        let url = try archive("reader-validation")
        var data = try Data(contentsOf: url)
        let bytes = ZipBytes(data: data)
        let second = bytes.central + 46 + Int(bytes.u16(bytes.central + 28)) + Int(bytes.u16(bytes.central + 30))
        data.zipSet(UInt32(0), at: second)
        try data.write(to: url)
        // A successful probe only validates the layout. The caller still needs a valid reader and matching count.
        XCTAssertEqual(try ArchiveUpdater.probe(url: url).entryCount, 3)
        XCTAssertThrowsError(try ArchiveUpdater.open(url: url))
    }
}
