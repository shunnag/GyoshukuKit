import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipLZMALevelTests: XCTestCase {
    func testLZMA2AndLZMAPresetsWithEncryptionAndHeaderEncryption() throws {
        let root = try TestSupport.directory("7z-lzma-levels")
        let items = LZMAWriterTestSupport.items()
        for method in [SevenZipCompressionMethod.lzma2, .lzma] {
            for preset in LZMAWriterTestSupport.presets {
                for mode in 0..<3 {
                    let directory = try TestSupport.work(in: root), url = directory.appendingPathComponent("archive.7z")
                    let options = WriterOptions(sevenZipMethod: method, lzmaLevel: preset.level, lzmaExtreme: preset.extreme,
                        password: mode == 0 ? nil : "secret", encryptsSevenZipHeaders: mode == 2, compressionThreads: 4)
                    try LZMAWriterTestSupport.write(url, format: .sevenZip, options: options, items: items)
                    let listing = try LZMAWriterTestSupport.verify(url, items: items, password: options.password)
                    XCTAssertTrue(listing.contains("\(method == .lzma ? "LZMA" : "LZMA2"):\(preset.dictionaryLabel)"), listing)
                    let reader = try SevenZipEditSupport.reader(url, password: options.password)
                    let model = try XCTUnwrap(SevenZipEditModel.read(reader))
                    XCTAssertEqual(model.header.encrypted, mode == 2)
                    for folder in model.folders {
                        XCTAssertEqual(folder.coders.map(\.methodID), (mode > 0 ? [[6, 0xF1, 7, 1]] : [])
                            + [method == .lzma ? [3, 1, 1] : [0x21]])
                        let expected = method == .lzma ? Data([0x5D]) + littleEndianDictionary(preset.dictionary) : Data([preset.property])
                        XCTAssertEqual(folder.coders.last?.properties, Array(expected))
                        XCTAssertEqual(folder.bindPairs, mode > 0 ? [.init(input: 1, output: 0)] : [])
                    }
                }
            }
        }
    }

    func testLZMANilLevelIsSixAndIgnoresExtreme() throws {
        let directory = try TestSupport.directory("7z-lzma-nil")
        let items = LZMAWriterTestSupport.items()
        let a = directory.appendingPathComponent("nil.7z"), b = directory.appendingPathComponent("six.7z")
        try LZMAWriterTestSupport.write(a, format: .sevenZip, options: .init(sevenZipMethod: .lzma, lzmaExtreme: true), items: items)
        try LZMAWriterTestSupport.write(b, format: .sevenZip, options: .init(sevenZipMethod: .lzma, lzmaLevel: 6), items: items)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        _ = try LZMAWriterTestSupport.verify(a, items: items)
        let reader = try SevenZipEditSupport.reader(a, password: nil)
        let model = try XCTUnwrap(SevenZipEditModel.read(reader))
        let range = model.packs[0].range
        let raw = try Data(contentsOf: a).subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        // EOS 無しを、サイズ未知の独立 decoder が終端を読めないことでも確かめる。
        let decoder = try LZMADecoder(source: DataByteSource(raw), offset: 0, compressedSize: UInt64(raw.count),
            properties: [0x5D, 0, 0, 0x80, 0], expectedSize: nil, dictionarySizeLimit: 64 << 20)
        var buffer = [UInt8](repeating: 0, count: 65536)
        XCTAssertThrowsError(try {
            while try buffer.withUnsafeMutableBytes({ try decoder.read(into: $0) }) != 0 {}
        }())
    }

    func testUpdaterAdditionAndSolidReencodeUseSelectedCoder() throws {
        let root = try TestSupport.directory("7z-lzma-update")
        for fixture in ["m", "z_aesh", "solid_zero"] {
            let source = SevenZipEditSupport.fixture(fixture)
            let reader = try SevenZipEditSupport.reader(source)
            let before = try XCTUnwrap(SevenZipEditModel.read(reader))
            let target = try XCTUnwrap(before.folders.indices.first { before.folders[$0].substreamIndices.count > 1 })
            let remove = try XCTUnwrap(before.filesByFolder[target].first { (reader.entries[$0].uncompressedSize ?? 0) > 0 })
            var items = try SevenZipEditSupport.items(reader)
            items.remove(at: remove)
            let expected = items.map { ExpectedEntry(name: $0.name, data: $0.data, kind: $0.kind, date: nil) }
            for method in [SevenZipCompressionMethod.lzma2, .lzma] {
                let directory = try TestSupport.work(in: root), output = directory.appendingPathComponent("updated.7z")
                let password = fixture == "z_aesh" ? "secret" : nil
                let options = WriterOptions(sevenZipMethod: method, lzmaLevel: 1, password: password,
                    encryptsSevenZipHeaders: password != nil, compressionThreads: 4)
                let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output, options: options)
                try updater.remove(entriesAt: [remove])
                let added = ExpectedEntry(name: "added", data: LZMAEncoderCorpus.text(size: 8193))
                try updater.add(data: added.data, as: added.name, modificationDate: TestSupport.date)
                try updater.commit()
                _ = try LZMAWriterTestSupport.verify(output, items: expected + [added], password: password, metadata: false)
                let afterReader = try SevenZipEditSupport.reader(output, password: password)
                let after = try XCTUnwrap(SevenZipEditModel.read(afterReader))
                for folder in [after.folders[target], try XCTUnwrap(after.folders.last)] {
                    XCTAssertEqual(folder.coders.last?.methodID, method == .lzma ? [3, 1, 1] : [0x21])
                    XCTAssertEqual(folder.coders.last?.properties, method == .lzma ? [0x5D, 0, 0, 0x10, 0] : [16])
                }
            }
        }
    }

    private func littleEndianDictionary(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    func testOwnLZMA2PiecesResetDictionaryAndKeepDeclaredSize() throws {
        let directory = try TestSupport.directory("7z-lzma-pieces")
        let item = ExpectedEntry(name: "text", data: LZMAEncoderCorpus.text(size: 3 * 65536))
        let url = directory.appendingPathComponent("archive.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
            options: .init(lzmaLevel: 9, compressionThreads: 4), lzmaChunkSize: 65536)
        try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
        try writer.finish()
        _ = try LZMAWriterTestSupport.verify(url, items: [item])
        let model = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(url, password: nil)))
        XCTAssertEqual(model.folders[0].coders[0].properties, [28])
        let bytes = try Data(contentsOf: url)
        let pack = model.packs[0].range
        var cursor = Int(pack.lowerBound), resets = 0
        while bytes[cursor] != 0 {
            let control = bytes[cursor]
            if control >= 0x80 {
                if control >= 0xE0 { resets += 1 }
                let size = (Int(bytes[cursor + 3]) << 8 | Int(bytes[cursor + 4])) + 1
                cursor += 5 + (control >= 0xC0 ? 1 : 0) + size
            } else {
                if control == 1 { resets += 1 }
                let size = (Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])) + 1
                cursor += 3 + size
            }
        }
        XCTAssertEqual(resets, 3)
        XCTAssertEqual(cursor + 1, Int(pack.upperBound))
    }

    func testRewriterUsesSelectedLZMAWithHeaderEncryption() throws {
        let directory = try TestSupport.directory("7z-lzma-rewrite")
        let source = directory.appendingPathComponent("source.tar")
        let item = ExpectedEntry(name: "text", data: LZMAEncoderCorpus.text(size: 8193))
        try LZMAWriterTestSupport.write(source, format: .tar, options: .init(), items: [item])
        for method in [SevenZipCompressionMethod.lzma2, .lzma] {
            let output = directory.appendingPathComponent("\(method).7z")
            let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .sevenZip,
                options: .init(sevenZipMethod: method, lzmaLevel: 0, password: "secret", encryptsSevenZipHeaders: true))
            try rewriter.commit()
            _ = try LZMAWriterTestSupport.verify(output, items: [item], password: "secret")
            let model = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(output, password: "secret")))
            XCTAssertEqual(model.folders[0].coders.last?.properties, method == .lzma ? [0x5D, 0, 0, 4, 0] : [12])
        }
    }
}
