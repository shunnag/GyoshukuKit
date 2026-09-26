import Foundation
import CryptoKit
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipHeaderSerializerTests: XCTestCase {
    func testFrozenHeaders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sevenzip-edit")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("expected-structures.json"))) as? [String: Any])
        let archives = try XCTUnwrap(json["archives"] as? [String: [String: Any]])
        for name in archives.keys.sorted() where name != "empty_7zz.7z" {
            let reader = try ArchiveReader.open(url: root.appendingPathComponent(name), options: SevenZipEditModel.readerOptions(password: "secret"))
            let model = try XCTUnwrap(SevenZipEditModel.read(reader), name)
            if model.unrepresentedReason != nil { continue }
            let bytes = try SevenZipHeaderSerializer.header(model)
            if model.files.isEmpty { XCTAssertEqual(bytes, Data([1, 5, 0, 0, 0]), name); continue }
            let expected = try XCTUnwrap(archives[name]?["plaintextHeader"] as? [String: Any], name)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expected["sha256"] as? String, name)
        }
    }

    func testNumberDigestAndPropertyOrder() throws {
        XCTAssertEqual(SevenZipRecords.number(127), Data([127]))
        XCTAssertEqual(SevenZipRecords.number(128), Data([0x80, 0x80]))
        XCTAssertEqual(SevenZipRecords.number(.max), Data(repeating: 255, count: 9))
        var data = Data()
        SevenZipHeaderSerializer.digests([nil, 0x12345678, nil], to: &data)
        XCTAssertEqual(data, Data([10, 0, 0x40, 0x78, 0x56, 0x34, 0x12]))
        XCTAssertEqual(SevenZipHeaderSerializer.propertyOrder(original: [0x11, 0x14, 0x12, 0x13, 0x15],
            needed: [0x0E, 0x11, 0x14, 0x12, 0x13, 0x18, 0x15]), [0x0E, 0x11, 0x14, 0x12, 0x13, 0x18, 0x15])
    }
}
