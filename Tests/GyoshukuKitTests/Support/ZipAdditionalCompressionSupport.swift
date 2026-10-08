import Foundation
import XCTest
@testable import GyoshukuKit

enum ZipAdditionalCompressionSupport {
    static let methods: [CompressionMethod] = [.bzip2, .xz]
    static let password = "ZIP-追加方式-256"

    // 製品の serializer を使わず、APPNOTE の中央 directory の長さから各 record を切り出す。
    static func centralRecords(_ archive: URL) throws -> [Data] {
        let bytes = ZipBytes(data: try Data(contentsOf: archive))
        var cursor = bytes.central
        var records: [Data] = []
        while bytes.u32(cursor) == 0x02014B50 {
            let length = 46 + Int(bytes.u16(cursor + 28)) + Int(bytes.u16(cursor + 30)) + Int(bytes.u16(cursor + 32))
            records.append(bytes.data.subdata(in: cursor..<(cursor + length)))
            cursor += length
        }
        return records
    }

    static func verify(_ archive: URL, expected: [ExpectedEntry], method: CompressionMethod,
                       password: String? = nil, aes: Bool = false) throws {
        let directory = archive.deletingLastPathComponent()
        let passwordArgs = password.map { ["-p\($0)"] } ?? []
        let test = try TestSupport.run(ReferenceTool.sevenZip, ["t", archive.path] + passwordArgs,
                                       in: directory, log: "7zz-t")
        XCTAssertTrue(test.contains("Everything is Ok"), test)
        let listing = try TestSupport.run(ReferenceTool.sevenZip, ["l", "-slt", archive.path] + passwordArgs,
                                          in: directory, log: "7zz-l")
        let blocks = listing.components(separatedBy: "----------\n").last!.components(separatedBy: "\n\n")
        for item in expected where item.kind == .file && !item.data.isEmpty && !item.name.hasSuffix(".PNG") {
            let block = try XCTUnwrap(blocks.first { $0.hasPrefix("Path = \(item.name)\n") }, item.name)
            let reported = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix("Method = ") })
            // 7-Zip 26.03 は method 95 を小文字の xz と表示する。
            XCTAssertTrue(reported.lowercased().contains(method == .bzip2 ? "bzip2" : "xz"), String(reported))
            if aes { XCTAssertTrue(reported.contains("AES-256"), String(reported)) }
        }
        let extracted = directory.appendingPathComponent("extracted")
        try TestSupport.run(ReferenceTool.sevenZip, ["x", "-y", "-o\(extracted.path)", archive.path] + passwordArgs,
                            in: directory, log: "7zz-x")
        for item in expected {
            let file = extracted.appendingPathComponent(item.name)
            switch item.kind {
            case .file: XCTAssertEqual(try Data(contentsOf: file), item.data, item.name)
            case .symlink:
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path),
                               String(decoding: item.data, as: UTF8.self), item.name)
            case .directory:
                var isDirectory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), item.name)
                XCTAssertTrue(isDirectory.boolValue, item.name)
            default: XCTFail("unexpected fixture kind")
            }
        }
        try TestSupport.assertKaitoKitRoundTrip(archive, expected: expected, password: password)
    }
}
