import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ParallelZIP64BoundaryTests: XCTestCase {
    func testIncompressibleMemberCrossesCompressedZIP64Threshold() throws {
        let directory = try TestSupport.directory("m8-zip64-compressed-boundary")
        let url = directory.appendingPathComponent("archive.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let blockSize = 64 * 1024
        let input = LHATestSupport.random(blockSize)
        let dictionary = DeflateBlock.dictionary(from: input)
        let first = try DeflateBlock.encode(.init(input: input, dictionary: Data(), final: false), level: 6)
        let middle = try DeflateBlock.encode(.init(input: input, dictionary: dictionary, final: false), level: 6)
        let last = try DeflateBlock.encode(.init(input: input, dictionary: dictionary, final: true), level: 6)
        let fixed = UInt64(first.count + last.count)
        let blocks = (ZipRecords.limit - fixed + UInt64(middle.count) - 1) / UInt64(middle.count)
        let size = (blocks + 2) * UInt64(blockSize)
        let compressed = fixed + blocks * UInt64(middle.count)
        XCTAssertLessThan(size, ZipRecords.limit)
        XCTAssertGreaterThanOrEqual(compressed, ZipRecords.limit)
        XCTAssertLessThan(size + (size >> 12) + (size >> 14) + (size >> 25) + 13, ZipRecords.limit)
        XCTAssertGreaterThanOrEqual(try DeflateBlock.bound(size: size, blockSize: blockSize), compressed)

        let writer = try ArchiveWriter.create(url: url, format: .zip, options: WriterOptions(compressionThreads: 8),
            deflateBlockSize: blockSize, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        var remaining = size
        try writer.addEntry(path: "random", mode: 0o100644, size: size, date: TestSupport.date, atime: nil, owners: nil) { count in
            guard remaining > 0 else { return Data() }
            XCTAssertEqual(count, blockSize)
            remaining -= UInt64(count)
            return input
        }
        try writer.finish()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = ZipBytes(data: try XCTUnwrap(handle.read(upToCount: 128)))
        XCTAssertEqual(header.u16(4), 45)
        XCTAssertEqual(header.u16(6), 0x0800)
        XCTAssertEqual(header.u32(18), UInt32.max)
        XCTAssertEqual(header.u32(22), UInt32.max)
        let extra = ZipBytes(data: try XCTUnwrap(header.extras(0, local: true)[1]))
        XCTAssertEqual(extra.u64(0), size)
        XCTAssertEqual(extra.u64(8), compressed)
        let reader = try ArchiveReader.open(url: url,
            options: ReaderOptions(limits: ReadLimits(maxEntrySize: max(size, compressed))))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.uncompressedSize, size)
        XCTAssertEqual(entry.compressedSize, compressed)
        let stream = try reader.stream(entry)
        let repeated = input + input
        var buffer = Data(count: blockSize), total: UInt64 = 0
        var crc = CRC32()
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            let start = Int(total % UInt64(blockSize))
            let chunk = buffer.prefix(count)
            XCTAssertEqual(chunk, repeated[start..<(start + count)])
            crc.update(chunk)
            total += UInt64(count)
        }
        XCTAssertEqual(total, size)
        XCTAssertEqual(entry.crc32, crc.value)
        TestSupport.report("PARALLEL ZIP64 random input=\(size), compressed=\(compressed); every byte verified")
        for candidates in [[ReferenceTool.unzip], [ReferenceTool.sevenZip, "/usr/local/bin/7zz"]] {
            let tool = try ReferenceTool.firstAvailable(candidates)
            try TestSupport.run(tool, [tool.hasSuffix("unzip") ? "-t" : "t", url.path], in: directory,
                                   log: tool.hasSuffix("unzip") ? "unzip-test" : "7zz-test")
        }
    }
}
