import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipAdditionalCompressionEditingTests: XCTestCase {
    private let old = Data("既存の deflate entry はそのまま運ぶ\n".utf8)
    private let added = Data(repeating: 0x61, count: 1024 * 1024)

    private func original(in directory: URL, format: GyoshukuKit.ArchiveFormat = .zip) throws -> URL {
        let archive = directory.appendingPathComponent("source." + format.testFileExtension)
        let writer = try ArchiveWriter.create(url: archive, format: format)
        try writer.add(data: old, as: "old.txt", modificationDate: TestSupport.date)
        try writer.finish()
        return archive
    }

    private func append(encryption: ZipEncryption?) throws {
        let directory = try TestSupport.directory("zip-additional-update-\(String(describing: encryption))")
        let archive = try original(in: directory)
        let password = encryption.map { _ in ZipAdditionalCompressionSupport.password }
        var expected: [ExpectedEntry] = [.init(name: "old.txt", data: old)]
        for method in ZipAdditionalCompressionSupport.methods {
            let before = ZipBytes(data: try Data(contentsOf: archive))
            let oldRecords = try ZipAdditionalCompressionSupport.centralRecords(archive)
            let updater = try ArchiveUpdater.open(url: archive, options: .init(compressionMethod: method, password: password,
                                                                              zipEncryption: encryption ?? .aes256, compressionThreads: 2))
            let name = "\(method).txt"
            // 一つは data の API、もう一つは updater の一括 disk 追加を通す。
            if method == .bzip2 {
                try updater.add(data: added, as: name, modificationDate: TestSupport.date)
            } else {
                let disk = directory.appendingPathComponent("disk-input")
                try added.write(to: disk)
                try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: disk.path)
                try updater.add([.init(path: name, source: .contents(of: disk))], events: nil)
            }
            try updater.commit()
            let after = ZipBytes(data: try Data(contentsOf: archive))
            let records = try ZipAdditionalCompressionSupport.centralRecords(archive)
            XCTAssertEqual(Array(records.prefix(oldRecords.count)), oldRecords)
            XCTAssertEqual(after.data.prefix(before.central), before.data.prefix(before.central))
            let last = ZipBytes(data: try XCTUnwrap(records.last))
            XCTAssertEqual(last.u16(10), encryption == .aes256 ? 99 : method.rawValue)
            if encryption == .aes256 {
                let aes = try XCTUnwrap(last.extras(0, local: false)[0x9901])
                XCTAssertEqual(ZipBytes(data: aes).u16(5), method.rawValue)
            }
            expected.append(.init(name: name, data: added))
            try TestSupport.assertKaitoKitRoundTrip(archive, expected: expected, password: password)
            let result = try TestSupport.run(ReferenceTool.sevenZip, ["t", archive.path] + (password.map { ["-p\($0)"] } ?? []),
                                             in: directory, log: "7zz-t-\(method)")
            XCTAssertTrue(result.contains("Everything is Ok"), result)
        }
    }

    func testUpdaterAddsBothMethodsAndPreservesCarriedRecords() throws { try append(encryption: nil) }
    func testUpdaterAddsBothAESMethodsAndPreservesCarriedRecords() throws { try append(encryption: .aes256) }
    func testUpdaterAddsBothZipCryptoMethodsAndPreservesCarriedRecords() throws { try append(encryption: .zipCrypto) }

    func testArchiveRewriterToZIPUsesSelectedMethodForCarriedAndAddedEntries() throws {
        for method in ZipAdditionalCompressionSupport.methods {
            let directory = try TestSupport.directory("zip-additional-rewrite-\(method)")
            let source = try original(in: directory, format: .tar)
            let archive = directory.appendingPathComponent("rewritten.zip")
            let rewriter = try ArchiveRewriter.open(url: source, output: archive, format: .zip,
                                                  options: .init(compressionMethod: method, compressionThreads: 2))
            try rewriter.add(data: added, as: "added.txt", modificationDate: TestSupport.date)
            try rewriter.commit()
            try ZipAdditionalCompressionSupport.verify(archive, expected: [
                .init(name: "old.txt", data: old), .init(name: "added.txt", data: added)
            ], method: method)
        }
    }
}
