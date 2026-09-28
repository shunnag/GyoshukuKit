import Foundation
import CryptoKit
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

/// 7-Zip と bsdtar で 7z 書庫を検査・展開し、KaitoKit で読んだ全 entry の内容と照合する。
enum SevenZipExternalOracles {
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip) && FileManager.default.isExecutableFile(atPath: ReferenceTool.bsdtar)
    }
    static func check(_ output: URL, password: String?, permitsStartPosRejection: Bool = false) throws {
        guard available else { return }
        // Keep reference-tool artifacts away from the transaction's cleanup assertions.
        let parent = TestPaths.verification.appendingPathComponent("7z-external-oracles")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = try TestSupport.work(in: parent)
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
