import Foundation
import Compression
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum EncryptionTestSupport {
    static let password = "Gyoshuku-test-2026"

    typealias Item = ExpectedEntry

    static var corpus: [Item] {
        [0, 5, 19, 20, 21].map { Item(name: "size-\($0).txt", data: Data(repeating: 0x41, count: $0)) }
        + [Item(name: "deflated.txt", data: Data(repeating: 0x51, count: 1024 * 1024)),
           Item(name: "stored.jpg", data: Data((0..<(1024 * 1024 + 31)).map { UInt8(truncatingIfNeeded: $0) })),
           Item(name: "directory/", kind: .directory),
           Item(name: "link", data: Data("size-5.txt".utf8), kind: .symlink)]
    }

    static func writeCorpus(_ writer: ArchiveWriter, in directory: URL) throws {
        for item in corpus {
            switch item.kind {
            case .directory: try writer.addDirectory(item.name)
            case .symlink:
                let link = directory.appendingPathComponent("source-link")
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "size-5.txt")
                try writer.add(contentsOf: link, as: item.name)
            default: try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
            }
        }
    }

    /// 名前・種類・内容と、entry ごとの暗号化の有無を照合する。大きさ・permission・更新日時は見ない。
    @discardableResult
    static func verify(_ url: URL, items: [Item], password: String? = EncryptionTestSupport.password,
                       encrypted: (Item) -> Bool) throws -> ArchiveReader {
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items, password: password, comparesMetadata: false) { entry, item in
            XCTAssertEqual(entry.isEncrypted, encrypted(item), item.name)
        }
    }

    // 失敗 oracle も実行し、password prompt は EOF で終了させる。失敗を skip しない。
    @discardableResult
    static func run(_ arguments: [String], archive: URL, log: String, success: Bool = true,
                    tool: String = ReferenceTool.sevenZip) throws -> String {
        let output = try ReferenceTool.run(tool, arguments, in: archive.deletingLastPathComponent(), log: log,
                                           expect: success ? .success : .failure, stdin: .nullDevice)
        let text = output.utf8Text
        if success {
            for marker in ["headers error", "warning", "errors:"] {
                XCTAssertFalse(text.lowercased().contains(marker), text)
            }
        }
        TestSupport.report("ENCRYPTION REFERENCE \(log): exit \(output.status)")
        return text
    }

    static func spoolFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".gyoshuku-zipcrypto-") }
    }

    static func localRecords(_ url: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url)
        let data = try Data(contentsOf: url)
        return try Dictionary(uniqueKeysWithValues: reader.entries.map { entry in
            let raw = try XCTUnwrap(reader.rawRecord(of: entry))
            return (entry.name, data.subdata(in: Int(raw.recordRange.lowerBound)..<Int(raw.recordRange.upperBound)))
        })
    }

    static func fixture(in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent("original.txt")
        try Data("original encrypted content\n".utf8).write(to: input)
        let archive = directory.appendingPathComponent("source.zip")
        try run(["a", "-tzip", "-mem=AES256", "-p" + password, archive.path, input.path],
                archive: archive, log: "7zz-fixture")
        return archive
    }

    // 製品の compressor / chunk size を参照せず、Apple の buffer API を一度だけ呼ぶ oracle。
    // XZ framing だけを除き、7z の packed size と比較する（暗号化時の最大 15 byte pad は含める）。
    static func wholeBufferLZMA2(_ input: Data) throws -> XZLZMA2 {
        let capacity = input.count + max(65_536, input.count / 16)
        var output = Data(count: capacity)
        let count: Int = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(capacity),
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(input.count),
                    nil, COMPRESSION_LZMA)
            }
        }
        guard count > 0 else {
            XCTFail("Reference compression_encode_buffer failed")
            throw CocoaError(.fileWriteUnknown)
        }
        output.removeSubrange(count..<output.count)
        let result = try XZLZMA2.extract(output)
        XCTAssertEqual(result.uncompressedSize, UInt64(input.count))
        return result
    }
}
