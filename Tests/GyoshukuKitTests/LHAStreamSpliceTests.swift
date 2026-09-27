import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAStreamSpliceTests: XCTestCase {
    func testLargeMembersMatchS15SerialStreamAtEveryThreadCount() throws {
        let directory = try ZipTestSupport.directory("lha-parallel-streams")
        let large = 8 * 1_048_576 + 8191
        let cases = [
            ("text-above", 1_048_577, "text"), ("random-above", 1_048_577, "random"),
            ("text-two", 2_097_152, "text"), ("random-two", 2_097_152, "random"),
            ("text-eight", large, "text"), ("random-eight", large, "random"),
            ("mixed-halves", large, "halves"), ("mixed-stored", large, "stored")
        ]
        for (label, count, kind) in cases {
            let input: Data
            switch kind {
            case "text": input = Self.text(count)
            case "halves": input = Self.text(count / 2) + LHATestSupport.random(count - count / 2)
            case "stored": input = Self.text(512) + LHATestSupport.random(count - 512)
            default: input = LHATestSupport.random(count)
            }
            let reference = try Self.serialStream(input, name: label)
            if label == "mixed-stored" || label == "random-eight" {
                XCTAssertEqual(reference.method, "-lh0-", label)
                XCTAssertGreaterThan(reference.unreadAtStop, 0, "\(label): must stop before reading the last piece")
            }
            if kind == "text" || kind == "halves" { XCTAssertEqual(reference.method, "-lh5-", label) }
            let before = try LHAWriterParallelTests.serialMember(Data([65]), name: "before")
            let after = try LHAWriterParallelTests.serialMember(Data([66]), name: "after")
            let emptyDirectory = try LHAWriterParallelTests.serialMember(Data(), name: "directory/", directory: true)
            let expected = before + reference.bytes + emptyDirectory + after + Data([0])
            for threads in [1, 4, 8, 16] {
                let url = directory.appendingPathComponent("\(label)-\(threads).lzh")
                let writer = try ArchiveWriter.create(url: url, format: .lha,
                                                      options: WriterOptions(compressionThreads: threads))
                let observer = try writer.duplicateOutput()
                defer { try? observer.close() }
                try writer.add(data: Data([65]), as: "before", modificationDate: ZipTestSupport.date)
                try writer.add(data: input, as: label, modificationDate: ZipTestSupport.date)
                XCTAssertEqual(try observer.offset(), UInt64(before.count + reference.bytes.count), "\(label), threads=\(threads)")
                try writer.addDirectory("directory", modificationDate: ZipTestSupport.date, ownerIDs: nil)
                try writer.add(data: Data([66]), as: "after", modificationDate: ZipTestSupport.date)
                try writer.finish()
                XCTAssertTrue(try Data(contentsOf: url) == expected, "\(label), threads=\(threads)")
                if threads == 16 {
                    let reader = try ArchiveReader.open(url: url)
                    XCTAssertEqual(reader.entries.map(\.name), ["before", label, "directory/", "after"])
                    XCTAssertEqual(try reader.read(reader.entries[1]), input, label)
                }
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".gyoshuku-") })
    }

    func testBitSplicingAtEveryStartingAndEndingBitPosition() {
        for start in 0..<8 {
            for tail in 0..<8 {
                for byteCount in [0, 1, 257] {
                    var reference = LH5Encoder.Bits(), merged = LH5Encoder.Bits()
                    let prefix = (1 << start) - 1
                    reference.write(prefix, count: start)
                    merged.write(prefix, count: start)
                    var actual = Data()
                    for piece in 0..<3 {
                        var bits = LH5Encoder.Bits()
                        for index in 0..<byteCount {
                            let value = (index * 37 + piece * 51) & 255
                            bits.write(value, count: 8)
                            reference.write(value, count: 8)
                        }
                        let remainder = ((1 << tail) - 1) ^ (piece & ((1 << tail) - 1))
                        bits.write(remainder, count: tail)
                        reference.write(remainder, count: tail)
                        let end = bits.remainder
                        XCTAssertEqual(end.count, tail)
                        XCTAssertEqual(end.value, UInt64(remainder))
                        let bytes = bits.takeCompleteBytes()
                        XCTAssertEqual(bits.remainder.count, tail)
                        XCTAssertEqual(bits.remainder.value, end.value)
                        merged.append(bytes, remainder: end)
                        actual.append(merged.takeCompleteBytes())
                    }
                    actual.append(merged.finish())
                    XCTAssertEqual(actual, reference.finish(), "start=\(start), tail=\(tail), bytes=\(byteCount)")
                }
            }
        }
    }

    private static func text(_ count: Int) -> Data {
        let phrase = Array("The quick brown fox jumps over the lazy dog. LH5 keeps eight KiB of history.\n".utf8)
        return Data((0..<count).map { phrase[$0 % phrase.count] })
    }

    // d5c51b3 の addStreamed。出力と spool だけ Data に置き換え、Bits は全区切りで一本を使う。
    private static func serialStream(_ source: Data, name: String) throws -> (bytes: Data, method: String, unreadAtStop: Int) {
        let size = UInt64(source.count)
        let entry = try LHARecords.Entry(name: name, mode: 0o100644, size: size, date: ZipTestSupport.date)
        let placeholder = try entry.header(method: "-lh0-", packedSize: entry.size, crc: 0)
        var output = placeholder
        let payloadOffset = output.count
        var remaining = size
        var crc: UInt16 = 0
        var bits = LH5Encoder.Bits()
        var compressing = true
        var history = Data()
        var spool = Data()
        var offset = 0, unreadAtStop = 0
        while remaining > 0 {
            var input = history
            let prefixSize = history.count
            let target = prefixSize + Int(min(UInt64(1_048_576), remaining))
            input.reserveCapacity(target)
            while input.count < target {
                let requested = min(256 * 1024, target - input.count)
                let chunk = source.subdata(in: offset..<(offset + requested))
                offset += chunk.count
                output.append(chunk)
                crc = LHACRC16.update(crc, chunk)
                input.append(chunk)
                remaining -= UInt64(chunk.count)
            }
            if compressing {
                try LH5Encoder.write(input, startingAt: prefixSize, to: &bits)
                history = Data(input.suffix(LH5Encoder.windowSize))
                spool.append(bits.takeCompleteBytes())
                compressing = spool.count < size
                if !compressing { unreadAtStop = Int(remaining) }
            }
        }
        if compressing { spool.append(bits.finish()) }
        let shrinks = compressing && spool.count < size
        let packedSize = shrinks ? UInt64(spool.count) : size
        if shrinks { output.replaceSubrange(payloadOffset..<output.count, with: spool) }
        let method = shrinks ? "-lh5-" : "-lh0-"
        let header = try entry.header(method: method, packedSize: UInt32(packedSize), crc: crc)
        XCTAssertEqual(header.count, placeholder.count)
        output.replaceSubrange(0..<payloadOffset, with: header)
        return (output, method, unreadAtStop)
    }
}
