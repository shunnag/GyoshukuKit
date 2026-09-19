import Darwin
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipUpdaterIntegrityTests: XCTestCase {
    private func fixture(_ label: String) throws -> URL {
        let directory = try ZipTestSupport.directory("zip-integrity-" + label)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored))
        try writer.add(data: Data(repeating: 0x61, count: 512), as: "first.bin", modificationDate: ZipTestSupport.date)
        try writer.add(data: Data("second payload".utf8), as: "other.bin", modificationDate: ZipTestSupport.date)
        try writer.finish()
        return url
    }

    private func embeddedEnd(_ data: Data) -> Data {
        let bytes = ZipBytes(data: data)
        var fake = Data(data.suffix(22))
        fake.zipSet(bytes.u32(bytes.end + 12) + 30, at: 12)
        fake.zipSet(UInt16(4), at: 20)
        var result = data
        result.zipSet(UInt16(34), at: bytes.end + 20)
        result.append(Data("filler!!".utf8))
        result.append(fake)
        result.append(Data("tail".utf8))
        return result
    }

    private func assertAmbiguous(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let UpdaterError.editingRefused(gatekeeper, reason) = error else {
            return XCTFail("expected ambiguousEndRecord, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(gatekeeper.rawValue, "ambiguousEndRecord", file: file, line: line)
        XCTAssertEqual(reason, gatekeeper.reason, file: file, line: line)
        ZipTestSupport.report("G4 gate: \(gatekeeper.rawValue): \(reason)")
    }

    private func assertInvalid(_ body: () throws -> Void, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) {
            guard case let UpdaterError.invalidArchive(reason) = $0 else {
                return XCTFail("expected invalidArchive, got \($0)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
            ZipTestSupport.report("G4 invalidArchive: \(reason)")
        }
    }

    func testEmbeddedCoherentEOCDIsRefusedBeforeAppendCanLoseEntries() throws {
        let url = try fixture("embedded-end")
        let bytes = embeddedEnd(try Data(contentsOf: url))
        try bytes.write(to: url)
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.count, 2, "reader must recover the legitimate EOCD")
        var accepted: ArchiveUpdater?
        XCTAssertThrowsError(accepted = try ArchiveUpdater.open(url: url), "open must refuse an embedded coherent EOCD") {
            assertAmbiguous($0)
        }
        XCTAssertThrowsError(try ArchiveUpdater.probe(url: url), "probe must refuse an embedded coherent EOCD") {
            assertAmbiguous($0)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        if let accepted {
            // Exercise and assert the old data-loss path only when the refusal regression returns.
            try accepted.add(data: Data("must remain visible".utf8), as: "added.txt")
            try accepted.commit()
            let names = try ArchiveReader.open(url: url).entries.map(\.name)
            XCTAssertEqual(names.count, 2, "red-run fixture must reproduce the old reader fallback")
            ZipTestSupport.report("G4 RED append: before=2, after=\(names.count), added.txt visible=\(names.contains("added.txt"))")
            XCTAssertEqual(names.count, 3, "committed append must expose the added entry")
        }
    }

    func testEnclosingEarlierCommentIsAmbiguousEvenWithTrailingData() throws {
        let url = try fixture("enclosing-end")
        let bytes = embeddedEnd(try Data(contentsOf: url)) + Data("trailing".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try ArchiveUpdater.open(url: url)) { assertAmbiguous($0) }
        XCTAssertThrowsError(try ArchiveUpdater.probe(url: url)) { assertAmbiguous($0) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testIncoherentEOCDBytesInLegitimateCommentRemainEditable() throws {
        let url = try fixture("incoherent-end")
        var bytes = try Data(contentsOf: url)
        var comment = Data([0x50, 0x4B, 0x05, 0x06])
        comment.append(Data(repeating: 0xFF, count: 22)) // Comment length 65535 does not fit.
        bytes.zipSet(UInt16(comment.count), at: bytes.count - 2)
        bytes.append(comment)
        try bytes.write(to: url)
        XCTAssertEqual(try ArchiveUpdater.probe(url: url).entryCount, 2)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(data: Data([7]), as: "added.txt")
        try updater.commit()
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name), ["first.bin", "other.bin", "added.txt"])
        XCTAssertEqual(try ZipUpdateLayout(source: ZipUpdateSource(url: url)).comment, comment)
    }

    func testCentralWalkRejectsPlantedPayloadSignature() throws {
        let url = try fixture("planted-central")
        var bytes = try Data(contentsOf: url)
        let original = ZipBytes(data: bytes)
        let planted = 30 + Int(original.u16(26)) + Int(original.u16(28)) + 8
        let firstSize = 46 + Int(original.u16(original.central + 28)) + Int(original.u16(original.central + 30))
        bytes.replaceSubrange(planted..<(planted + firstSize),
                              with: bytes.subdata(in: original.central..<(original.central + firstSize)))
        try bytes.write(to: url)
        let reader = try ArchiveReader.open(url: url)
        let source = try ZipUpdateSource(url: url)
        // Validate this forged layout directly: the ambiguity gate must not be the only defence.
        assertInvalid({
            try ZipCentralDirectory.validate(source: source, reader: reader,
                centralOffset: UInt64(planted), centralSize: UInt64(original.end - planted))
        }, "CD walk must refuse a central signature planted inside a carried payload")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCentralWalkRequiresExactDeclaredEnd() throws {
        let url = try fixture("central-end")
        let source = try ZipUpdateSource(url: url)
        let layout = try ZipUpdateLayout(source: source)
        let reader = try ArchiveReader.open(url: url)
        assertInvalid({
            try ZipCentralDirectory.validate(source: source, reader: reader,
                centralOffset: layout.centralOffset, centralSize: layout.centralSize + 22)
        }, "CD walk must end exactly at the declared central-directory end")
    }

    func testOpenRejectsLocalPayloadOverlappingCentralDirectoryBeforeAdd() throws {
        let url = try fixture("local-overlaps-central")
        var data = try Data(contentsOf: url)
        let bytes = ZipBytes(data: data)
        for offset in [18, 22, bytes.central + 20, bytes.central + 24] {
            data.zipSet(UInt32(bytes.central), at: offset)
        }
        try data.write(to: url)
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.count, 2)
        XCTAssertEqual(try ArchiveUpdater.probe(url: url).entryCount, 2, "tail-only probe leaves local ranges to open")
        assertInvalid({ _ = try ArchiveUpdater.open(url: url) },
                      "open must validate local ranges before an append can overwrite them")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testCentralWalkRejectsReaderLocalOffsetDisagreement() throws {
        let url = try fixture("central-local-offset")
        var bytes = try Data(contentsOf: url)
        let reader = try ArchiveReader.open(data: bytes)
        let original = ZipBytes(data: bytes)
        let second = original.central + 46 + Int(original.u16(original.central + 28)) + Int(original.u16(original.central + 30))
        bytes.zipSet(UInt32(0), at: second + 42)
        try bytes.write(to: url)
        assertInvalid({
            try ZipCentralDirectory.validate(source: ZipUpdateSource(url: url), reader: reader,
                centralOffset: UInt64(original.central), centralSize: UInt64(original.end - original.central))
        }, "CD local offsets must agree with the reader's raw records")
    }

    func testFinishRejectsMalformedOrMiscountedCopiedCentralRecords() throws {
        let url = try fixture("copied-central-invalid")
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        let central = bytes.data.subdata(in: bytes.central..<bytes.end)
        var badSignature = central
        badSignature[0] = 0
        let variants: [(Data, UInt64)] = [
            (badSignature, 2), (Data(central.dropLast()), 2), (central, 3),
            (central + Data(bytes.data.suffix(22)), 2), (central, 0)
        ]
        for (index, variant) in variants.enumerated() {
            let output = url.deletingLastPathComponent().appendingPathComponent("bad-\(index).zip")
            let writer = try ArchiveWriter.create(url: output)
            assertInvalid({
                try writer.finish(existingCount: variant.1, comment: Data()) { emit in try emit(variant.0) }
            }, "finish must validate copied old-CD records (variant \(index))")
        }
    }

    func testFinishAcceptsCentralRecordsAcrossArbitraryChunkBoundaries() throws {
        let url = try fixture("copied-central-valid")
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        let central = bytes.data.subdata(in: bytes.central..<bytes.end)
        for chunkSize in [1, 7, 47, 257] {
            let output = url.deletingLastPathComponent().appendingPathComponent("chunk-\(chunkSize).zip")
            try bytes.data.prefix(bytes.central).write(to: output)
            let handle = try FileHandle(forUpdating: output)
            var info = stat()
            XCTAssertEqual(fstat(handle.fileDescriptor, &info), 0)
            let writer = ArchiveWriter(output: handle, url: output, identity: (info.st_dev, info.st_ino),
                                       format: .zip, options: .init())
            try writer.prepareAppend(at: UInt64(bytes.central), existingPaths: [("first.bin", false), ("other.bin", false)])
            try writer.add(data: Data([7]), as: "added.txt")
            try writer.finish(existingCount: 2, comment: Data()) { emit in
                for cursor in stride(from: 0, to: central.count, by: chunkSize) {
                    try emit(central.subdata(in: cursor..<min(cursor + chunkSize, central.count)))
                }
            }
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map(\.name), ["first.bin", "other.bin", "added.txt"])
            XCTAssertEqual(try reader.read(reader.entries[0]), Data(repeating: 0x61, count: 512))
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("second payload".utf8))
            XCTAssertEqual(try reader.read(reader.entries[2]), Data([7]))
        }
    }

    func testCentralWalkResolvesZIP64OffsetAfterBothSizeFields() throws {
        let url = try fixture("central-zip64-offset")
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        let nameEnd = bytes.central + 46 + Int(bytes.u16(bytes.central + 28))
        var zip64 = Data()
        zip64.le(UInt16(1)); zip64.le(UInt16(24))
        zip64.le(UInt64(bytes.u32(bytes.central + 24)))
        zip64.le(UInt64(bytes.u32(bytes.central + 20)))
        zip64.le(UInt64(bytes.u32(bytes.central + 42)))
        var patched = bytes.data
        patched.zipSet(UInt16(45), at: bytes.central + 6)
        patched.zipSet(UInt32.max, at: bytes.central + 20)
        patched.zipSet(UInt32.max, at: bytes.central + 24)
        patched.zipSet(UInt32.max, at: bytes.central + 42)
        patched.zipSet(bytes.u16(bytes.central + 30) + UInt16(zip64.count), at: bytes.central + 30)
        patched.insert(contentsOf: zip64, at: nameEnd)
        patched.zipSet(bytes.u32(bytes.end + 12) + UInt32(zip64.count), at: patched.count - 10)
        try patched.write(to: url)
        let updater = try ArchiveUpdater.open(url: url)
        try updater.add(data: Data([7]), as: "added.txt")
        try updater.commit()
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.count, 3)
    }
}
