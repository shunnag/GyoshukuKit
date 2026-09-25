import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarRepeatEditTests: XCTestCase {
    func testFiftySeededEditsUsingAdoptedAndReopenedSnapshots() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try ZipTestSupport.directory("p3-repeat-\(format)")
            var current = try CompressedTarTestSupport.fixture(root, format)
            var plainURL = root.appendingPathComponent("input.tar")
            var reader = try CompressedTarTestSupport.open(current)
            var seed: UInt64 = 17, largestSmallCount = 0
            for step in 0..<50 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let session = try (step % 2 == 0 ? reader.reopen() : CompressedTarTestSupport.open(current))
                let base = session.tarEditingSnapshot()!
                let index = 2 + Int((seed >> 16) % UInt64(session.entries.count - 2))
                let oldName = session.entries[index].name
                let operation = Int((seed >> 32) % 4)
                let mutate: (any ArchiveEditing) throws -> Void = { editor in
                    switch operation {
                    case 0: try editor.remove(entriesAt: [index])
                    case 1: try editor.rename(entryAt: index, to: "renamed-\(step)-" + String(repeating: "n", count: step % 2 == 0 ? 140 : 8))
                    case 2: try editor.add(data: Data(repeating: UInt8(step), count: 4096), as: "added-\(step)", modificationDate: ZipTestSupport.date, permissions: nil)
                    default:
                        try editor.remove(entriesAt: [index])
                        try editor.add(data: Data([UInt8(step)]), as: oldName, modificationDate: ZipTestSupport.date, permissions: nil)
                    }
                }
                let output = root.appendingPathComponent("step-\(step)." + TarP2Support.suffix(format))
                let plainOutput = root.appendingPathComponent("step-\(step).tar")
                let plain = try TarUpdater.open(url: plainURL, output: plainOutput)
                try mutate(plain); try plain.commit()
                let editor = try CompressedTarUpdater.open(reader: session.reopen(), output: output, format: format)
                try mutate(editor)
                let result = try editor.commit(progress: nil)
                reader = try CompressedTarTestSupport.verify(output, base: base, result: result, oracle: plainOutput)
                let limit = UInt64(CompressedTarSplicePlan.limit(format, options: WriterOptions()) / 16)
                let small = reader.tarEditingSnapshot()!.chunkMap!.chunks.filter { $0.imageRange.upperBound - $0.imageRange.lowerBound < limit }.count
                largestSmallCount = max(largestSmallCount, small)
                XCTAssertLessThanOrEqual(small, 8, "\(format) step \(step)")
                if step == 49 {
                    let encoded = root.appendingPathComponent("full." + TarP2Support.suffix(format))
                    let full = try CompressedTarUpdater.open(reader: session.reopen(), output: encoded, format: format)
                    try mutate(full)
                    let forced = try CompressedTarUpdater.$testingForcesFullEncode.withValue(true) { try full.commit(progress: nil) }
                    _ = try CompressedTarTestSupport.verify(encoded, base: base, result: forced, oracle: plainOutput)
                    XCTAssertLessThanOrEqual(Double(result.output.size), Double(forced.output.size) * 1.01)
                    ZipTestSupport.report("TAR-REPEAT \(format)\tseed=17\tedits=50\tsplice=\(result.output.size)\tfull=\(forced.output.size)\tsmall_max=\(largestSmallCount)")
                }
                current = output; plainURL = plainOutput
            }
        }
    }
}

final class CompressedTarLargeOffsetTests: XCTestCase {
    func testLargeCRCAndImageOffsets() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_LARGE_TESTS"] == "1" else { throw XCTSkip("Set GYOSHUKU_LARGE_TESTS=1") }
        let zeros = Data(count: 1024 * 1024), prefix = Data("prefix".utf8)
        var suffixCRC: UInt32 = 0, direct = updateCRC(0, prefix)
        for _ in 0..<4608 { suffixCRC = updateCRC(suffixCRC, zeros); direct = updateCRC(direct, zeros) }
        let length: UInt64 = 4608 * 1024 * 1024
        XCTAssertEqual(compressedTarCRCCombine(updateCRC(0, prefix), suffixCRC, length), direct)
        let footer = CompressedTarSpliceWriter.gzipTrailer(crc: direct, imageLength: length)
        XCTAssertEqual(footer.zip32(4), 512 * 1024 * 1024)
        let unpadded = (UInt64(1) << 32) + 9, unpacked = (UInt64(1) << 32) + 513
        let record = XZFraming.vli(unpadded) + XZFraming.vli(unpacked)
        XCTAssertEqual(record, Data([0x89, 0x80, 0x80, 0x80, 0x10, 0x81, 0x84, 0x80, 0x80, 0x10]))
        var framed = Data()
        try XZFraming.emitIndexAndFooter(records: record, blockCount: 1) { framed.append($0) }
        XCTAssertEqual(framed[2..<(2 + record.count)], record)
        let source = LargePatternSource(length: length)
        let offset = (UInt64(1) << 32) + 127
        let image = TarImageSource(spans: [.init(source: source, offset: offset, range: 0..<4096, isOld: true)], length: 4096, terminalStart: 4096)
        let actual = try TarLayout.bytes(image, at: 0, count: 4096)
        XCTAssertEqual(actual, Data((0..<4096).map { UInt8((offset + UInt64($0)) % 251) }))
        ZipTestSupport.report("TAR-LARGE length=\(length) crc=\(direct) offset=\(offset) passed")
    }
    private struct LargePatternSource: ByteSource {
        let length: UInt64
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let count = Int(min(UInt64(buffer.count), length - min(length, offset)))
            for index in 0..<count { buffer[index] = UInt8((offset + UInt64(index)) % 251) }
            return count
        }
    }
}
