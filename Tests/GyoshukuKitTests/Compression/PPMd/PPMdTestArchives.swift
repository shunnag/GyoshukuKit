// 出自: PPMd stream は公開ドメインの LZMA SDK 26.03 C/Ppmd7Enc.c / 7-Zip 26.03 C/Ppmd8Enc.c に基づく。
// この試験用 container は 7z format description と PKWARE APPNOTE §4 / §5.10 から独立に組み立てる。
import Foundation
import XCTest
@testable import GyoshukuKit

enum PPMdTestArchives {
    static func directory(_ label: String) throws -> URL {
        // debug / release の照合を同時に走らせても oracle の一時出力を共有しない。
        #if DEBUG
        return try TestSupport.directory(label + "-debug")
        #else
        return try TestSupport.directory(label + "-release")
        #endif
    }

    static func crc(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((0 &- (value & 1)) & 0xEDB8_8320) }
        }
        return ~value
    }

    static func little(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func number(_ value: UInt64) -> Data {
        for extra in 0..<8 {
            if value < UInt64(1) << (7 * (extra + 1)) {
                let prefix = UInt8(truncatingIfNeeded: 0xFF << (8 - extra))
                return Data([prefix | UInt8(value >> (extra * 8))]) + little(value, bytes: extra)
            }
        }
        return Data([0xFF]) + little(value, bytes: 8)
    }

    /// Copy coder を含まない一つの folder、plain next header、一つの file。
    static func sevenZip(_ payload: Data, input: Data, properties: PPMd7EncoderProperties) -> Data {
        let packedCRC = little(UInt64(crc(payload)), bytes: 4)
        let plainCRC = little(UInt64(crc(input)), bytes: 4)
        var header = Data([0x01, 0x04, 0x06, 0x00, 0x01, 0x09])
        header.append(number(UInt64(payload.count)))
        header.append(Data([0x0A, 0x01])); header.append(packedCRC); header.append(0)
        header.append(Data([0x07, 0x0B, 0x01, 0x00, 0x01, 0x23, 0x03, 0x04, 0x01, 0x05]))
        header.append(properties.coderProperties)
        header.append(0x0C); header.append(number(UInt64(input.count)))
        header.append(Data([0x0A, 0x01])); header.append(plainCRC)
        header.append(Data([0x00, 0x00, 0x05, 0x01, 0x11]))
        var name = Data([0])
        for unit in "payload.bin".utf16 { name.append(little(UInt64(unit), bytes: 2)) }
        name.append(Data([0, 0]))
        header.append(number(UInt64(name.count))); header.append(name)
        header.append(Data([0, 0]))
        var start = little(UInt64(payload.count), bytes: 8)
        start.append(little(UInt64(header.count), bytes: 8))
        start.append(little(UInt64(crc(header)), bytes: 4))
        var archive = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04])
        archive.append(little(UInt64(crc(start)), bytes: 4)); archive.append(start)
        archive.append(payload); archive.append(header)
        return archive
    }

    static func zip(_ payload: Data, input: Data) -> Data {
        let name = Data("payload.bin".utf8)
        var fields = little(63, bytes: 2) + little(0x0800, bytes: 2) + little(98, bytes: 2)
        fields.append(little(0, bytes: 2)); fields.append(little(0x0021, bytes: 2))
        fields.append(little(UInt64(crc(input)), bytes: 4))
        fields.append(little(UInt64(payload.count), bytes: 4)); fields.append(little(UInt64(input.count), bytes: 4))
        fields.append(little(UInt64(name.count), bytes: 2)); fields.append(little(0, bytes: 2))
        var archive = little(0x04034B50, bytes: 4) + fields + name + payload
        let offset = archive.count
        var central = little(0x02014B50, bytes: 4) + little(0x033F, bytes: 2) + fields
        central.append(Data(repeating: 0, count: 14)); central.append(name)
        archive.append(central)
        archive.append(little(0x06054B50, bytes: 4)); archive.append(Data(repeating: 0, count: 4))
        archive.append(little(1, bytes: 2)); archive.append(little(1, bytes: 2))
        archive.append(little(UInt64(central.count), bytes: 4)); archive.append(little(UInt64(offset), bytes: 4))
        archive.append(little(0, bytes: 2))
        return archive
    }

    static func verify(_ archive: Data, input: Data, extension ext: String,
                       method: String, label: String, directory: URL) throws {
        let url = directory.appendingPathComponent(label + "." + ext)
        try archive.write(to: url)
        TestSupport.report("PPMd oracle: \(label), input=\(input.count), archive=\(archive.count)")
        try StreamEncoderTestSupport.assertKaito(url, equals: input)
        try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path], in: directory, log: label + "-test")
        try StreamEncoderTestSupport.assertCLI(ReferenceTool.sevenZip, arguments: ["x", "-so"], url: url,
                                              input: input, in: directory, label: label + "-extract")
        let list = try ReferenceTool.run(ReferenceTool.sevenZip, ["l", "-slt", url.path], in: directory, log: label + "-list")
        XCTAssertTrue(list.text.contains("Method = " + method), list.text)
    }
}
