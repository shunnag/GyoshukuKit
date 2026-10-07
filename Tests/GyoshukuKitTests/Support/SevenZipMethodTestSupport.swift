import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

enum SevenZipMethodTestSupport {
    struct Method {
        let value: SevenZipCompressionMethod
        let name: String
        let id: [UInt8]
    }
    // 製品の method ID 定数から期待値を作らず、DOC/Methods.txt の表を固定する。
    static let methods: [Method] = [
        .init(value: .lzma2, name: "LZMA2", id: [0x21]),
        .init(value: .copy, name: "Copy", id: [0]),
        .init(value: .deflate, name: "Deflate", id: [4, 1, 8]),
        .init(value: .bzip2, name: "BZip2", id: [4, 2, 2])
    ]
    static var additionalMethods: [Method] { Array(methods.dropFirst()) }

    static func options(_ method: Method, mode: Int, threads: Int = 4) -> WriterOptions {
        WriterOptions(sevenZipMethod: method.value, password: mode == 0 ? nil : "secret",
                      encryptsSevenZipHeaders: mode == 2, compressionThreads: threads)
    }
    static func corpus() -> [ExpectedEntry] {
        [.init(name: "one", data: Data([0xA5])),
         .init(name: "text.txt", data: TestCorpus.pseudoSource(mebibytes: 1)),
         .init(name: "random.png", data: TestCorpus.random(8 * 1024 * 1024)),
         .init(name: "empty"),
         .init(name: "empty-directory/", kind: .directory, permissions: 0o755),
         .init(name: "日本語-é.txt", data: Data("圧縮方式の往復\n".utf8))]
    }
    static func write(_ url: URL, items: [ExpectedEntry], options: WriterOptions) throws {
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: options)
        for item in items {
            if item.kind == .directory {
                try writer.addDirectory(item.name, modificationDate: TestSupport.date, ownerIDs: nil)
            } else {
                try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.permissions)
            }
        }
        try writer.finish()
    }
    static func assertMethod(_ folder: SevenZipEditModel.Folder, method: Method, encrypted: Bool) throws {
        XCTAssertEqual(folder.coders.map(\.methodID), (encrypted ? [[6, 0xF1, 7, 1]] : []) + [method.id])
        let coder = try XCTUnwrap(folder.coders.last)
        XCTAssertEqual(coder.inputCount, 1); XCTAssertEqual(coder.outputCount, 1)
        XCTAssertFalse(coder.isComplex)
        if method.value == .lzma2 { XCTAssertEqual(coder.properties?.count, 1) }
        else { XCTAssertNil(coder.properties) }
        XCTAssertEqual(folder.bindPairs, encrypted ? [.init(input: 1, output: 0)] : [])
        XCTAssertEqual(folder.packedInputs, [0])
    }

    /// 必須の実ツールで t / l / x を実行し、KaitoKit と展開先の双方を元の byte と照合する。
    @discardableResult
    static func verify(_ url: URL, items: [ExpectedEntry], password: String?,
                       method: Method? = nil, ordered: Bool = true, metadata: Bool = true,
                       observeListing: ((String) -> Void)? = nil) throws -> SevenZipEditModel {
        let reader = try SevenZipEditSupport.reader(url, password: password)
        func key(_ name: String) -> String { name.hasSuffix("/") ? String(name.dropLast()) : name }
        let expectedByName = Dictionary(uniqueKeysWithValues: items.map { (key($0.name), $0) })
        let expected = ordered ? items : try reader.entries.map { entry in
            var item = try XCTUnwrap(expectedByName[key(entry.name)])
            // 7zz の directory 名は末尾の / を持たない。
            item.name = entry.name
            return item
        }
        XCTAssertEqual(Set(reader.entries.map { key($0.name) }), Set(items.map { key($0.name) }))
        try TestSupport.assertKaitoKitRoundTrip(url, expected: expected, password: password, comparesMetadata: metadata, reader: reader)
        let model = try XCTUnwrap(SevenZipEditModel.read(reader))
        if let method {
            for folder in model.folders { try assertMethod(folder, method: method, encrypted: password != nil) }
        }
        let work = try TestSupport.work(in: url.deletingLastPathComponent())
        let arguments = password.map { ["-p" + $0] } ?? []
        try TestSupport.run(ReferenceTool.sevenZip, ["t", "-y"] + arguments + [url.path], in: work, log: "7zz-t")
        let listing = try TestSupport.run(ReferenceTool.sevenZip, ["l", "-slt"] + arguments + [url.path], in: work, log: "7zz-l")
        observeListing?(listing)
        let listed = SevenZipTestSupport.listingEntries(listing)
        XCTAssertEqual(listed.count, items.count)
        if let method {
            for entry in listed where UInt64(entry["Size"] ?? "0") != 0 {
                let text = entry["Method"] ?? ""
                XCTAssertTrue(text.contains(method.name), text)
                XCTAssertEqual(text.contains("7zAES:"), password != nil, text)
            }
        }
        let extracted = work.appendingPathComponent("extracted")
        try TestSupport.run(ReferenceTool.sevenZip, ["x", "-y"] + arguments + ["-o" + extracted.path, url.path],
                            in: work, log: "7zz-x")
        for item in items {
            let path = extracted.appendingPathComponent(item.name)
            if item.kind == .directory {
                var directory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path, isDirectory: &directory))
                XCTAssertTrue(directory.boolValue)
            } else { XCTAssertEqual(try Data(contentsOf: path), item.data, item.name) }
        }
        return model
    }
}
