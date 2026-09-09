import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class Zip64WriterTests: XCTestCase {
    func testZIP64UncompressedSizeAbove4GiBRoundTrips() throws {
        let directory = try ZipTestSupport.directory("zip64-size")
        let source = directory.appendingPathComponent("zeros.bin")
        let size: UInt64 = (1 << 32) + (1 << 20)
        // 入力作成だけ sparse file を使う。writer は穴を検出せず全 byte を読む。
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let input = try FileHandle(forWritingTo: source)
        try input.truncate(atOffset: size)
        try input.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .modificationDate: ZipTestSupport.date], ofItemAtPath: source.path)
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url, options: WriterOptions(useCompressionHeuristic: false))
        try writer.add(contentsOf: source, as: "zeros.bin")
        try writer.finish()
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertLessThan(bytes.data.count, 5 * 1024 * 1024)
        XCTAssertEqual(bytes.u16(6), 0x0800)
        XCTAssertEqual(bytes.u16(4), 45)
        XCTAssertEqual(bytes.u32(22), UInt32.max)
        XCTAssertEqual(bytes.u32(18), UInt32.max)
        let local = ZipBytes(data: try XCTUnwrap(bytes.extras(0, local: true)[1]))
        XCTAssertEqual(local.data.count, 16)
        XCTAssertEqual(local.u64(0), size)
        XCTAssertEqual(local.u64(8), UInt64(bytes.u32(bytes.central + 20)))
        let central = ZipBytes(data: try XCTUnwrap(bytes.extras(bytes.central, local: false)[1]))
        XCTAssertEqual(central.data.count, 8)
        XCTAssertEqual(central.u64(0), size)
        XCTAssertEqual(bytes.u32(bytes.central + 24), UInt32.max)
        XCTAssertLessThan(bytes.u32(bytes.central + 20), UInt32.max)
        XCTAssertEqual(bytes.u32(bytes.central + 42), 0)
        // CD 自体の count/size/offset が収まるとき EOCD は通常幅のまま。
        XCTAssertEqual(bytes.u32(bytes.end), 0x06054B50)
        XCTAssertEqual(bytes.end, bytes.central + 46 + Int(bytes.u16(bytes.central + 28)) + Int(bytes.u16(bytes.central + 30)))
        let unzip = try ZipTestSupport.run("/usr/bin/unzip", ["-t", url.path], in: directory, log: "unzip-t")
        XCTAssertTrue(unzip.contains("No errors detected"))
        let listing = try ZipTestSupport.run("/usr/bin/unzip", ["-l", url.path], in: directory, log: "unzip-l")
        XCTAssertTrue(listing.contains("\(size)"))
        XCTAssertTrue(listing.contains("zeros.bin"))
        let sevenTest = try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", url.path], in: directory, log: "7zz-t")
        XCTAssertTrue(sevenTest.contains("Everything is Ok"))
        let sevenList = try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["l", url.path], in: directory, log: "7zz-l")
        XCTAssertTrue(sevenList.contains("\(size)"))
        let extracted = directory.appendingPathComponent("ditto")
        try ZipTestSupport.run("/usr/bin/ditto", ["-x", "-k", url.path, extracted.path], in: directory, log: "ditto-x")
        try ZipTestSupport.run("/usr/bin/cmp", [source.path, extracted.appendingPathComponent("zeros.bin").path], in: directory, log: "cmp")
        try ZipTestSupport.run("/usr/bin/tar", ["-tf", url.path], in: directory, log: "bsdtar-t")
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: ReadLimits(maxEntrySize: size)))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(entry.name, "zeros.bin")
        XCTAssertEqual(entry.uncompressedSize, size)
        XCTAssertEqual(entry.posixPermissions, 0o644)
        XCTAssertEqual(entry.modificationDate, ZipTestSupport.date)
        XCTAssertEqual(entry.compressedSize, UInt64(bytes.u32(bytes.central + 20)))
        let stream = try reader.stream(entry)
        let zeros = Data(repeating: 0, count: 256 * 1024)
        var buffer = Data(count: zeros.count)
        var total: UInt64 = 0
        var crc = CRC32()
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            let chunk = buffer.prefix(count)
            XCTAssertEqual(chunk, zeros.prefix(count))
            crc.update(chunk)
            total += UInt64(count)
        }
        XCTAssertEqual(total, size)
        XCTAssertEqual(entry.crc32, crc.value)
        ZipTestSupport.report("KAITO ZIP64 size=\(total) compressed=\(entry.compressedSize!) CRC=\(String(crc.value, radix: 16)); every byte verified")
        // 巨大な展開物だけは残さず、検証に使った小さい書庫とログを保存する。
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: extracted)
    }

    func testZIP64MoreThan65535EntriesRoundTrips() throws {
        let directory = try ZipTestSupport.directory("zip64-count")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        var expected: [ZipTestSupport.Expected] = []
        for index in 0..<65_536 {
            let name = String(format: "entry-%05d", index)
            try writer.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
            expected.append(.init(name: name))
        }
        try writer.finish()
        let bytes = ZipBytes(data: try Data(contentsOf: url))
        XCTAssertEqual(bytes.u16(bytes.end + 8), UInt16.max)
        XCTAssertEqual(bytes.u16(bytes.end + 10), UInt16.max)
        XCTAssertNotEqual(bytes.u32(bytes.end + 12), UInt32.max)
        XCTAssertNotEqual(bytes.u32(bytes.end + 16), UInt32.max)
        XCTAssertEqual(bytes.u32(bytes.end - 20), 0x07064B50)
        let zip64End = Int(bytes.u64(bytes.end - 12))
        XCTAssertEqual(bytes.u32(zip64End), 0x06064B50)
        XCTAssertEqual(bytes.u64(zip64End + 24), 65_536)
        XCTAssertEqual(bytes.u64(zip64End + 32), 65_536)
        XCTAssertEqual(bytes.u64(zip64End + 48), UInt64(bytes.central))
        try ZipTestSupport.verify(url, expected: expected)
        ZipTestSupport.report("KAITO ZIP64 count=65536; all names, bytes, dates, permissions and CRCs verified")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ditto"))
    }

    func testZIP64PerFieldSentinelsAtExactBoundaries() throws {
        let limit = UInt64(UInt32.max)
        // 大きい出力を作らず、offset / compressed size と正確な sentinel 境界を検査する。
        for (size, compressed, offset) in [(limit - 1, UInt64(17), UInt64(0)), (limit, 17, 0), (17, limit, 0), (17, 19, limit), (limit, limit, limit)] {
            let entry = ZipRecords.Entry(name: Data("x".utf8), method: .deflate, mtime: 0, atime: 0,
                                         dosTime: 0, dosDate: 0x21, mode: 0o100644, owners: nil,
                                         offset: offset, size: size, compressedSize: compressed)
            let central = ZipBytes(data: entry.central())
            XCTAssertEqual(central.u32(24), UInt32(min(size, limit)))
            XCTAssertEqual(central.u32(20), UInt32(min(compressed, limit)))
            XCTAssertEqual(central.u32(42), UInt32(min(offset, limit)))
            let fields = [size >= limit ? size : nil, compressed >= limit ? compressed : nil, offset >= limit ? offset : nil].compactMap { $0 }
            let extra = central.extras(0, local: false)[1]
            XCTAssertEqual(extra?.count ?? 0, fields.count * 8)
            if let extra {
                for (index, value) in fields.enumerated() { XCTAssertEqual(ZipBytes(data: extra).u64(index * 8), value) }
            }
            let local = ZipBytes(data: entry.local())
            if size >= limit || compressed >= limit {
                XCTAssertEqual(local.u32(18), UInt32.max)
                XCTAssertEqual(local.u32(22), UInt32.max)
                let extra = ZipBytes(data: try XCTUnwrap(local.extras(0, local: true)[1]))
                XCTAssertEqual(extra.data.count, 16)
                XCTAssertEqual(extra.u64(0), size)
                XCTAssertEqual(extra.u64(8), compressed)
            } else { XCTAssertNil(local.extras(0, local: true)[1]) }
        }
        for (count, size, offset) in [(UInt64(65_534), limit - 1, limit - 1), (65_535, 17, 19), (1, limit, 19), (1, 17, limit)] {
            let bytes = ZipBytes(data: try ZipRecords.end(count: count, centralSize: size, centralOffset: offset))
            XCTAssertEqual(bytes.u16(bytes.end + 8), UInt16(min(count, 65_535)))
            XCTAssertEqual(bytes.u32(bytes.end + 12), UInt32(min(size, limit)))
            XCTAssertEqual(bytes.u32(bytes.end + 16), UInt32(min(offset, limit)))
            XCTAssertEqual(bytes.data.count, count >= 65_535 || size >= limit || offset >= limit ? 98 : 22)
        }
        XCTAssertThrowsError(try ZipRecords.end(count: 1, centralSize: UInt64.max, centralOffset: 1))
    }
}
