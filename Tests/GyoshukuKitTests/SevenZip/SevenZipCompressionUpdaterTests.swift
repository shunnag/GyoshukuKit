import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipCompressionUpdaterTests: XCTestCase {
    func testAddSelectedMethodKeepsLZMA2FoldersByteIdentical() throws {
        let root = try TestSupport.directory("7z-methods-add")
        let data = TestCorpus.pseudoSource(mebibytes: 2)
        for mode in 0..<3 {
            let originalDirectory = try TestSupport.work(in: root)
            let source = try SevenZipEditSupport.source(originalDirectory, password: mode == 0 ? nil : "secret", headers: mode == 2)
            let original = try SevenZipEditSupport.reader(source, password: mode == 0 ? nil : "secret")
            let before = try XCTUnwrap(SevenZipEditModel.read(original))
            let items = try SevenZipEditSupport.items(original)
            for method in SevenZipMethodTestSupport.additionalMethods {
                for sequential in [false, true] {
                    let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
                    let options = SevenZipMethodTestSupport.options(method, mode: mode)
                    let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                        try SevenZipUpdater.open(url: source, password: options.password, output: output, options: options)
                    }
                    try updater.add(data: data, as: "追加.txt", modificationDate: TestSupport.date)
                    try updater.add(data: Data(), as: "added-empty", modificationDate: TestSupport.date)
                    try updater.finishAdditions(progress: { progress in
                        XCTAssertLessThanOrEqual(progress.completedBytes, progress.totalBytes)
                    })
                    try updater.commit()
                    let reader = try SevenZipEditSupport.reader(output, password: options.password)
                    XCTAssertEqual(try SevenZipEditSupport.items(reader), items + [
                        .init(name: "追加.txt", kind: .file, data: data), .init(name: "added-empty", kind: .file, data: Data())
                    ])
                    let after = try XCTUnwrap(SevenZipEditModel.read(reader))
                    XCTAssertEqual(after.header.encrypted, mode == 2)
                    try SevenZipEditSupport.assertCarried(source, output, originalModel: before, outputModel: after,
                                                         pairs: before.folders.indices.map { ($0, $0) })
                    try SevenZipMethodTestSupport.assertMethod(try XCTUnwrap(after.folders.last), method: method, encrypted: mode != 0)
                    try SevenZipExternalOracles.check(output, password: options.password)
                }
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testSolidDeletionUsesSelectedMethodAndKeepsOtherFolders() throws {
        let root = try TestSupport.directory("7z-methods-solid")
        for name in ["m", "z_aes", "z_aesh", "solid_zero"] {
            let source = SevenZipEditSupport.fixture(name)
            let original = try SevenZipEditSupport.reader(source)
            let before = try XCTUnwrap(SevenZipEditModel.read(original))
            let target = try XCTUnwrap(before.folders.indices.first { before.folders[$0].substreamIndices.count > 1 })
            let remove = try XCTUnwrap(before.filesByFolder[target].first { original.entries[$0].uncompressedSize != 0 })
            var expected = try SevenZipEditSupport.items(original)
            expected.remove(at: remove)
            for method in SevenZipMethodTestSupport.additionalMethods {
                for sequential in [false, true] {
                    let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
                    let encrypted = before.folders[target].isEncrypted
                    let options = WriterOptions(sevenZipMethod: method.value, password: encrypted ? "secret" : nil,
                        encryptsSevenZipHeaders: before.header.encrypted, compressionThreads: 4)
                    let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                        try SevenZipUpdater.open(url: source, password: "secret", output: output, options: options)
                    }
                    try updater.remove(entriesAt: [remove])
                    try updater.add(data: Data([4, 8]), as: "added", modificationDate: TestSupport.date)
                    try updater.commit()
                    let reader = try SevenZipEditSupport.reader(output, password: options.password)
                    XCTAssertEqual(try SevenZipEditSupport.items(reader), expected + [.init(name: "added", kind: .file, data: Data([4, 8]))])
                    let after = try XCTUnwrap(SevenZipEditModel.read(reader))
                    try SevenZipMethodTestSupport.assertMethod(after.folders[target], method: method, encrypted: encrypted)
                    try SevenZipMethodTestSupport.assertMethod(try XCTUnwrap(after.folders.last), method: method, encrypted: encrypted)
                    try SevenZipEditSupport.assertCarried(source, output, originalModel: before, outputModel: after,
                                                         pairs: before.folders.indices.filter { $0 != target }.map { ($0, $0) })
                    try SevenZipExternalOracles.check(output, password: options.password)
                }
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testSolidReencodingDuringPasswordChangeUsesSelectedMethod() throws {
        let root = try TestSupport.directory("7z-methods-solid-password")
        let source = SevenZipEditSupport.fixture("z_aesh")
        let original = try SevenZipEditSupport.reader(source)
        let before = try XCTUnwrap(SevenZipEditModel.read(original))
        let target = try XCTUnwrap(before.folders.indices.first { before.folders[$0].substreamIndices.count > 1 })
        let remove = try XCTUnwrap(before.filesByFolder[target].first)
        var expected = try SevenZipEditSupport.items(original)
        expected.remove(at: remove)
        for method in SevenZipMethodTestSupport.additionalMethods {
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
            let options = WriterOptions(sevenZipMethod: method.value, password: "new", encryptsSevenZipHeaders: true)
            let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output, options: options)
            try updater.remove(entriesAt: [remove])
            try updater.reencryptExistingEntries(currentPassword: "secret")
            try updater.commit()
            let reader = try SevenZipEditSupport.reader(output, password: "new")
            XCTAssertEqual(try SevenZipEditSupport.items(reader), expected)
            let after = try XCTUnwrap(SevenZipEditModel.read(reader))
            try SevenZipMethodTestSupport.assertMethod(after.folders[target], method: method, encrypted: true)
            try SevenZipExternalOracles.check(output, password: "new")
        }
    }

    func testAESAttachChangeDetachKeepsOriginalCompressionAndPackedPlaintext() throws {
        let root = try TestSupport.directory("7z-methods-aes-conversions")
        let items: [ExpectedEntry] = [.init(name: "one", data: Data([7])),
                                     .init(name: "text", data: TestCorpus.pseudoSource(mebibytes: 2))]
        for method in SevenZipMethodTestSupport.additionalMethods {
            let work = try TestSupport.work(in: root), plain = work.appendingPathComponent("plain.7z")
            try SevenZipMethodTestSupport.write(plain, items: items, options: SevenZipMethodTestSupport.options(method, mode: 0))
            let original = try SevenZipEditSupport.reader(plain, password: nil)
            let model = try XCTUnwrap(SevenZipEditModel.read(original))
            let bytes = try Data(contentsOf: plain)
            let packed = model.packs.map { bytes.subdata(in: Int($0.range.lowerBound)..<Int($0.range.upperBound)) }
            for sequential in [false, true] {
                var source = plain
                var currentPassword: String?
                for (index, password) in ["secret", "new", nil].enumerated() {
                    let output = work.appendingPathComponent("\(sequential)-\(index).7z")
                    // options の既定 LZMA2 へ変換せず、圧縮済み stream の AES だけを操作する。
                    let options = WriterOptions(password: password, encryptsSevenZipHeaders: password != nil)
                    let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                        try SevenZipUpdater.open(url: source, password: currentPassword, output: output, options: options)
                    }
                    try updater.reencryptExistingEntries(currentPassword: currentPassword)
                    try updater.commit()
                    let after = try SevenZipMethodTestSupport.verify(output, items: items, password: password, method: method)
                    let reader = try SevenZipEditSupport.reader(output, password: password)
                    let outputBytes = try Data(contentsOf: output)
                    for folder in after.folders.indices {
                        let plaintext: Data
                        if password != nil {
                            let stream = try reader.sevenZipDecryptedPackedStream(folder: folder, packedInput: 0)
                            var data = Data()
                            while true {
                                let chunk = try stream.readSome(upTo: IOChunk.size)
                                if chunk.isEmpty { break }; data.append(chunk)
                            }
                            plaintext = data
                        } else {
                            let range = after.packs[after.folders[folder].packIndices.lowerBound].range
                            plaintext = outputBytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
                        }
                        XCTAssertEqual(plaintext, packed[folder])
                    }
                    source = output; currentPassword = password
                }
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }
}
