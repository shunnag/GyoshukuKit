import Foundation
import CryptoKit
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

enum SevenZipEditSupport {
    static let fixtures = TestPaths.fixtures.appendingPathComponent("sevenzip-edit")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name + ".7z") }
    static func reader(_ url: URL, password: String? = "secret") throws -> ArchiveReader {
        try ArchiveReader.open(url: url, options: SevenZipEditModel.readerOptions(password: password))
    }
    struct Item: Equatable {
        var name: String
        var kind: EntryKind
        var data: Data
    }
    static func items(_ reader: ArchiveReader) throws -> [Item] {
        try reader.entries.map { entry in
            let bytes: Data
            do { bytes = try reader.read(entry) }
            catch KaitoError.wrongPassword {
                reader.password = reader.password == "secret" ? "secret2" : "secret"
                bytes = try reader.read(entry)
            }
            return Item(name: entry.name, kind: entry.kind, data: bytes)
        }
    }
    static func source(_ directory: URL, password: String? = nil, headers: Bool = false, count: Int = 4) throws -> URL {
        let url = directory.appendingPathComponent("source.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
            options: WriterOptions(password: password, encryptsSevenZipHeaders: headers, compressionThreads: 1))
        for i in 0..<count {
            try writer.add(data: Data(repeating: UInt8(truncatingIfNeeded: i), count: 1000 + i * 100), as: "file\(i)", modificationDate: ZipTestSupport.date)
        }
        try writer.addDirectory("dir", modificationDate: ZipTestSupport.date, ownerIDs: nil)
        try writer.add(data: Data(), as: "empty", modificationDate: ZipTestSupport.date)
        try writer.finish()
        return url
    }
    static func assertCarried(_ original: URL, _ output: URL, originalModel: SevenZipEditModel,
                              outputModel: SevenZipEditModel, pairs: [(Int, Int)], file: StaticString = #filePath, line: UInt = #line) throws {
        let old = try Data(contentsOf: original), new = try Data(contentsOf: output)
        for (a, b) in pairs {
            var left = originalModel.folders[a]
            let right = outputModel.folders[b]
            for (p, q) in zip(originalModel.packs[left.packIndices], outputModel.packs[right.packIndices]) {
                XCTAssertEqual(old.subdata(in: Int(p.range.lowerBound)..<Int(p.range.upperBound)),
                               new.subdata(in: Int(q.range.lowerBound)..<Int(q.range.upperBound)), file: file, line: line)
                XCTAssertEqual(p.crc32, q.crc32, file: file, line: line)
            }
            left.packIndices = right.packIndices; left.substreamIndices = right.substreamIndices
            XCTAssertEqual(left, right, file: file, line: line)
        }
    }
    static func work(_ root: URL) throws -> URL {
        let work = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }
}
