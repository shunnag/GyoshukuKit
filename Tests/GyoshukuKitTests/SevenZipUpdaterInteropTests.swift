import Foundation
import CryptoKit
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterInteropTests: XCTestCase {
    func testExternalReadersAndExtractionHashes() throws {
        guard SevenZipExternalOracles.available else { throw XCTSkip("7zz / bsdtar unavailable") }
        let root = try TestSupport.directory("7z-interop")
        for name in ["g_plain", "g_aes", "g_aesh", "z_default", "z_aes", "z_aesh", "z_aesonlyh", "z_special", "anti", "lib", "bcj", "bcj2", "ppmd", "solid_zero"] {
            let source = SevenZipEditSupport.fixture(name)
            let old = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(source)))
            for operation in ["rename", "delete", "all"] {
                let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output,
                    options: WriterOptions(password: "secret", encryptsSevenZipHeaders: old.header.encrypted))
                let first = old.files.firstIndex(where: \.hasStream) ?? 0
                if operation == "all" { try updater.remove(entriesAt: Array(old.files.indices)) }
                else if operation == "delete" { try updater.remove(entriesAt: [first]) }
                else { try updater.rename(entryAt: first, to: old.files[first].isEmptyFile || old.files[first].hasStream ? "renamed" : "renamed/") }
                try updater.commit()
                try SevenZipExternalOracles.check(output, password: "secret")
            }
        }
    }

    // Orchestrator's AC-G13 amendment: the frozen StartPos fixture already fails 7zz x
    // (7-Zip 26.03, exit 2, Unsupported Method). Preserve that value, including its bytes;
    // require the same rejection only while a StartPos entry remains. No other exception.
    func testStartPosBaselineAndPreservation() throws {
        guard SevenZipExternalOracles.available else { throw XCTSkip("7zz / bsdtar unavailable") }
        let root = try TestSupport.directory("7z-startpos-interop")
        let source = SevenZipEditSupport.fixture("startpos")
        let original = try SevenZipEditSupport.reader(source)
        let model = try XCTUnwrap(SevenZipEditModel.read(original))
        let items = try SevenZipEditSupport.items(original)
        let startIndex = try XCTUnwrap(model.files.firstIndex { $0.startPosition != nil })
        XCTAssertFalse(model.header.encoded)
        try SevenZipExternalOracles.check(source, password: nil, permitsStartPosRejection: true)
        for operation in ["rename", "delete", "all"] {
            let output = root.appendingPathComponent(operation + ".7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            var expected = items
            if operation == "rename" { try updater.rename(entryAt: startIndex, to: "renamed"); expected[startIndex].name = "renamed" }
            else if operation == "delete" { try updater.remove(entriesAt: [startIndex]); expected.remove(at: startIndex) }
            else { try updater.remove(entriesAt: Array(items.indices)); expected = [] }
            try updater.commit()
            let reader = try SevenZipEditSupport.reader(output)
            let edited = try XCTUnwrap(SevenZipEditModel.read(reader))
            XCTAssertEqual(try SevenZipEditSupport.items(reader), expected)
            if operation == "rename" {
                XCTAssertEqual(edited.files.map(\.startPosition), model.files.map(\.startPosition))
                let bytes = try Data(contentsOf: output)
                let header = bytes.subdata(in: Int(edited.nextHeaderRange.lowerBound)..<Int(edited.nextHeaderRange.upperBound))
                var rawValue = Data(); rawValue.le(model.files[startIndex].startPosition!)
                XCTAssertNotNil(header.range(of: rawValue))
                XCTAssertEqual(edited.substreams.map(\.crc32), model.substreams.map(\.crc32))
            } else { XCTAssertTrue(edited.files.allSatisfy { $0.startPosition == nil }) }
            for (index, entry) in reader.entries.enumerated() {
                if let crc = entry.crc32 { XCTAssertEqual(crc, CRC32.checksum(expected[index].data)) }
            }
            try SevenZipExternalOracles.check(output, password: nil, permitsStartPosRejection: true)
        }
    }
}

enum SevenZipExternalOracles {
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip) && FileManager.default.isExecutableFile(atPath: ReferenceTool.bsdtar)
    }
    static func check(_ output: URL, password: String?, permitsStartPosRejection: Bool = false) throws {
        guard available else { return }
        // Keep reference-tool artifacts away from the transaction's cleanup assertions.
        let parent = TestPaths.verification.appendingPathComponent("7z-external-oracles")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = try SevenZipEditSupport.work(parent)
        let reader = try SevenZipEditSupport.reader(output, password: password)
        let model = try XCTUnwrap(SevenZipEditModel.read(reader))
        let items = try SevenZipEditSupport.items(reader)
        let passwordArguments = password.map { ["-p" + $0] } ?? []
        try TestSupport.run(ReferenceTool.sevenZip, ["t", "-y"] + passwordArguments + [output.path], in: work, log: "7zz-t")
        let readers = model.header.encrypted || model.folders.contains(where: \.isEncrypted) ? ["7zz"] : ["7zz", "bsdtar"]
        for tool in readers {
            let target = work.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            if tool == "7zz" {
                let arguments = ["x", "-y"] + passwordArguments + ["-o" + target.path, output.path]
                if permitsStartPosRejection && model.files.contains(where: { $0.startPosition != nil }) {
                    let text = try ReferenceTool.run(ReferenceTool.sevenZip, arguments, in: work, log: "7zz-x",
                                                     expect: .oneOf([2]), environment: [:]).utf8Text
                    XCTAssertTrue(text.contains("ERROR: Unsupported Method :"), text)
                    XCTAssertFalse(text.contains("Headers Error"), text)
                    continue
                }
                try TestSupport.run(ReferenceTool.sevenZip, arguments, in: work, log: "7zz-x")
            } else {
                try TestSupport.run(ReferenceTool.bsdtar, ["-xf", output.path, "-C", target.path], in: work, log: "bsdtar-x")
            }
            for (index, item) in items.enumerated() {
                let path = target.appendingPathComponent(item.name)
                // An anti item has no payload: 7zz applies the deletion; bsdtar exposes
                // the empty placeholder (also true of the frozen baseline). Hash that below.
                if model.files[index].isAnti && tool == "7zz" {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "\(tool) anti: \(item.name)")
                    continue
                }
                if item.kind == .directory { XCTAssertTrue(FileManager.default.fileExists(atPath: path.path)); continue }
                let bytes = item.kind == .symlink ? Data(try FileManager.default.destinationOfSymbolicLink(atPath: path.path).utf8) : try Data(contentsOf: path)
                XCTAssertEqual(SHA256.hash(data: bytes), SHA256.hash(data: item.data), "\(tool): \(item.name)")
            }
        }
    }
}
