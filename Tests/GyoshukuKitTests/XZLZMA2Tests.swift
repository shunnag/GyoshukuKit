import Compression
import CryptoKit
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class XZLZMA2Tests: XCTestCase {
    func testAppleXZRetainsLZMA2TerminatorAndDecodes() throws {
        let directory = try ZipTestSupport.directory("7z-apple-xz")
        let input = Data(String(repeating: "Apple Compression LZMA2 payload\n", count: 1000).utf8)
        let container = try LZMA2Compressor.encodeXZ(input)
        let parsed = try XZLZMA2.extract(container)
        XCTAssertEqual(parsed.uncompressedSize, UInt64(input.count))
        XCTAssertEqual(parsed.properties, 0x16)
        XCTAssertEqual(parsed.payload.last, 0)
        XCTAssertEqual(container.subdata(in: parsed.payloadOffset..<(parsed.payloadOffset + parsed.payload.count)), parsed.payload)
        try assertDecodes(container, to: input)
        let url = directory.appendingPathComponent("apple.xz")
        try container.write(to: url)
        try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-apple-xz")
        // Data slice の startIndex に依存しないことも確かめる。
        let prefixed = Data([0xFF]) + container
        XCTAssertEqual(try XZLZMA2.extract(prefixed.dropFirst()).payload, parsed.payload)
    }

    func testOptionalSizeFieldsAndHeaderPaddingMovePayloadDynamically() throws {
        let directory = try ZipTestSupport.directory("7z-xz-optional-sizes")
        let input = Data((0..<20_003).map { UInt8(truncatingIfNeeded: $0) })
        let raw = try LZMA2Compressor.encode(input)
        var observedOffsets: Set<Int> = []
        for flags: UInt8 in [0, 0x40, 0x80, 0xC0] {
            let fixture = XZFixture(input: input, raw: raw, flags: flags, paddingWords: Int(flags >> 6), check: 1)
            let parsed = try XZLZMA2.extract(fixture.data)
            XCTAssertEqual(parsed.payloadOffset, fixture.payloadOffset)
            XCTAssertEqual(parsed.payload, raw.payload)
            XCTAssertEqual(parsed.properties, raw.properties)
            XCTAssertEqual(parsed.uncompressedSize, UInt64(input.count))
            observedOffsets.insert(parsed.payloadOffset)
            let url = directory.appendingPathComponent("flags-\(flags).xz")
            try fixture.data.write(to: url)
            try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-flags-\(flags)")
            try assertDecodes(fixture.data, to: input)
        }
        XCTAssertEqual(observedOffsets, [24, 28, 32, 40])
        ZipTestSupport.report("XZ OPTIONAL SIZE FIELDS: payload offsets \(observedOffsets.sorted()); CRC32 check excluded; 7zz accepted all fixtures")
    }

    func testNoneCRC32CRC64AndSHA256ChecksDoNotLeakIntoPayload() throws {
        let directory = try ZipTestSupport.directory("7z-xz-checks")
        let input = Data("container checks belong outside the raw LZMA2 stream".utf8)
        let raw = try LZMA2Compressor.encode(input)
        for check: UInt8 in [0, 1, 4, 10] {
            let fixture = XZFixture(input: input, raw: raw, flags: 0xC0, paddingWords: 2, check: check)
            let parsed = try XZLZMA2.extract(fixture.data)
            XCTAssertEqual(parsed.payload, raw.payload)
            XCTAssertEqual(parsed.payload.last, 0)
            XCTAssertEqual(parsed.uncompressedSize, UInt64(input.count))
            let padded = fixture.data + Data(count: 8)
            XCTAssertEqual(try XZLZMA2.extract(padded).payload, raw.payload)
            let url = directory.appendingPathComponent("check-\(check).xz")
            try padded.write(to: url)
            try SevenZipTestSupport.run(["t", url.path], in: directory, log: "7zz-check-\(check)")
        }
    }

    func testMalformedFramingTruncationAndUnsupportedFiltersAreRejected() throws {
        let input = Data("xz framing rejection fixture!".utf8)
        let raw = try LZMA2Compressor.encode(input)
        let fixture = XZFixture(input: input, raw: raw, flags: 0xC0, paddingWords: 2, check: 1)
        for count in 0..<fixture.data.count {
            XCTAssertThrowsError(try XZLZMA2.extract(fixture.data.prefix(count)), "truncated at \(count)")
        }
        // framing CRC 自体の破損を検査する。
        for offset in [0, 8, 12, fixture.payloadOffset - 4, fixture.footerOffset - 4, fixture.footerOffset, fixture.data.count - 1] {
            var data = fixture.data
            data[offset] ^= 1
            XCTAssertThrowsError(try XZLZMA2.extract(data), "corrupt at \(offset)")
        }
        // CRC を直しても、予約 bit・filter・property・宣言 size・padding の矛盾は拒否する。
        for (offset, value): (Int, UInt8) in [
            (13, 0xC1), (13, 0xC4), (14, UInt8(raw.payload.count + 1)),
            (15, UInt8(input.count + 1)), (16, 0x03), (17, 2), (18, 41), (19, 1)
        ] {
            var data = fixture.data
            data[offset] = value
            SevenZipTestSupport.patchCRC(&data, at: fixture.payloadOffset - 4, over: 12..<(fixture.payloadOffset - 4))
            XCTAssertThrowsError(try XZLZMA2.extract(data), "invalid header field at \(offset)")
        }
        for (relative, value): (Int, UInt8) in [(0, 1), (1, 2), (2, 0), (3, 0)] {
            var data = fixture.data
            data[fixture.indexOffset + relative] = value
            SevenZipTestSupport.patchCRC(&data, at: fixture.footerOffset - 4, over: fixture.indexOffset..<(fixture.footerOffset - 4))
            XCTAssertThrowsError(try XZLZMA2.extract(data), "invalid index field \(relative)")
        }
        var overlongVLI = fixture.data
        overlongVLI[fixture.indexOffset + 1] = 0x81
        overlongVLI[fixture.indexOffset + 2] = 0
        SevenZipTestSupport.patchCRC(&overlongVLI, at: fixture.footerOffset - 4, over: fixture.indexOffset..<(fixture.footerOffset - 4))
        XCTAssertThrowsError(try XZLZMA2.extract(overlongVLI))
        var footerFlags = fixture.data
        footerFlags[fixture.footerOffset + 9] = 4
        SevenZipTestSupport.patchCRC(&footerFlags, at: fixture.footerOffset, over: (fixture.footerOffset + 4)..<(fixture.footerOffset + 10))
        XCTAssertThrowsError(try XZLZMA2.extract(footerFlags))
        var hugeIndex = fixture.data
        hugeIndex.replaceSubrange((fixture.footerOffset + 4)..<(fixture.footerOffset + 8), with: [0xFF, 0xFF, 0xFF, 0xFF])
        SevenZipTestSupport.patchCRC(&hugeIndex, at: fixture.footerOffset, over: (fixture.footerOffset + 4)..<(fixture.footerOffset + 10))
        XCTAssertThrowsError(try XZLZMA2.extract(hugeIndex))
        var terminator = fixture.data
        terminator[fixture.payloadOffset + raw.payload.count - 1] = 1
        XCTAssertThrowsError(try XZLZMA2.extract(terminator))
        var blockPadding = fixture.data
        let paddingOffset = fixture.payloadOffset + raw.payload.count
        XCTAssertLessThan(paddingOffset, fixture.indexOffset - 4)
        blockPadding[paddingOffset] = 1
        XCTAssertThrowsError(try XZLZMA2.extract(blockPadding))
        XCTAssertThrowsError(try XZLZMA2.extract(fixture.data + Data([0])))
        XCTAssertThrowsError(try XZLZMA2.extract(fixture.data + fixture.data))
    }

    private func assertDecodes(_ container: Data, to expected: Data) throws {
        var decoded = Data(count: expected.count + 1)
        let capacity = decoded.count
        let count = container.withUnsafeBytes { input in
            decoded.withUnsafeMutableBytes { output in
                compression_decode_buffer(output.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                          input.baseAddress!.assumingMemoryBound(to: UInt8.self), container.count,
                                          nil, COMPRESSION_LZMA)
            }
        }
        XCTAssertEqual(count, expected.count)
        XCTAssertEqual(decoded.prefix(count), expected)
    }
}

// payload は Apple の出力をそのまま再利用し、可変 framing だけを組み立てる。LZMA encoder は持たない。
private struct XZFixture {
    let data: Data
    let payloadOffset: Int
    let indexOffset: Int
    let footerOffset: Int

    init(input: Data, raw: XZLZMA2, flags: UInt8, paddingWords: Int, check: UInt8) {
        var digest = Data()
        switch check {
        case 1: digest.le(CRC32.checksum(input))
        case 4:
            var crc = UInt64.max
            for byte in input {
                crc ^= UInt64(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xC96C_5795_D787_0F42) }
            }
            digest.le(~crc)
        case 10: digest = Data(SHA256.hash(data: input))
        default: break
        }
        var header = Data([0, flags])
        if flags & 0x40 != 0 { header.append(Self.vli(UInt64(raw.payload.count))) }
        if flags & 0x80 != 0 { header.append(Self.vli(UInt64(input.count))) }
        header.append(contentsOf: [0x21, 1, raw.properties])
        while header.count % 4 != 0 { header.append(0) }
        header.append(Data(count: paddingWords * 4))
        header[0] = UInt8(header.count / 4)
        header.le(CRC32.checksum(header))
        var container = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0, 0, check])
        container.le(CRC32.checksum(container.subdata(in: 6..<8)))
        container.append(header)
        payloadOffset = container.count
        container.append(raw.payload)
        while container.count % 4 != 0 { container.append(0) }
        container.append(digest)
        indexOffset = container.count
        var index = Data([0, 1])
        index.append(Self.vli(UInt64(header.count + raw.payload.count + digest.count)))
        index.append(Self.vli(UInt64(input.count)))
        while index.count % 4 != 0 { index.append(0) }
        index.le(CRC32.checksum(index))
        container.append(index)
        footerOffset = container.count
        var footer = Data()
        footer.le(UInt32(index.count / 4 - 1))
        footer.append(contentsOf: [0, check])
        container.le(CRC32.checksum(footer))
        container.append(footer)
        container.append(contentsOf: [0x59, 0x5A])
        data = container
    }

    private static func vli(_ value: UInt64) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            result.append(UInt8(remaining & 0x7F) | (remaining >= 128 ? 0x80 : 0))
            remaining >>= 7
        } while remaining > 0
        return result
    }
}
