import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterNewTarFormatTests: XCTestCase {
    private let payloads = [("remove", Data("remove me".utf8)), ("rename", Data("rename me".utf8)),
                            ("日本語.txt", Data("内容\n".utf8)), ("empty", Data())]

    private func fixture(_ directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source.zip")
        let writer = try ArchiveWriter.create(url: source)
        for (name, data) in payloads { try writer.add(data: data, as: name, modificationDate: TestSupport.date) }
        try writer.addDirectory("directory")
        try writer.finish()
        return source
    }

    private func verify(_ url: URL, payloads: [(String, Data)]) throws {
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.map(\.name), payloads.map(\.0) + ["directory/"])
        for (entry, item) in zip(reader.entries, payloads) { XCTAssertEqual(try reader.read(entry), item.1, item.0) }
        XCTAssertEqual(reader.entries.last?.kind, .directory)
    }

    func testZIPFixtureIntoEveryNewFormatAndBack() throws {
        for format in SingleStreamTestSupport.newTarFormats {
            let directory = try TestSupport.directory("rewriter-new-tar-\(format)")
            let source = try fixture(directory)
            let tar = directory.appendingPathComponent("output." + format.testFileExtension)
            try ArchiveRewriter.open(url: source, output: tar, format: format).commit()
            try verify(tar, payloads: payloads)
            _ = try SingleStreamTestSupport.tarTool(tar, format: SingleStreamTestSupport.format(format),
                                                  arguments: ["-tvf", "-"], in: directory, label: "tar-listing")
            let back = directory.appendingPathComponent("back.zip")
            try ArchiveRewriter.open(url: tar, output: back, format: .zip).commit()
            try verify(back, payloads: payloads)
            try ReferenceTool.run(ReferenceTool.unzip, ["-t", back.path], in: directory, log: "zip-test")
        }
    }

    func testDeleteRenameAddOnTarLZ4AndLzip() throws {
        for format in [GyoshukuKit.ArchiveFormat.tarLZ4, .tarLzip] {
            let directory = try TestSupport.directory("rewriter-new-tar-edit-\(format)")
            let zip = try fixture(directory)
            let source = directory.appendingPathComponent("source." + format.testFileExtension)
            try ArchiveRewriter.open(url: zip, output: source, format: format).commit()
            let editor = try ArchiveRewriter.open(url: source, format: format)
            try editor.remove(entriesAt: [0])
            try editor.rename(entryAt: 1, to: "renamed")
            let addition = Data("new file".utf8)
            try editor.add(data: addition, as: "added", modificationDate: TestSupport.date)
            try editor.commit()
            let reader = try ArchiveReader.open(url: source)
            XCTAssertEqual(reader.entries.map(\.name), ["renamed", "日本語.txt", "empty", "directory/", "added"])
            for (index, data) in [(0, payloads[1].1), (1, payloads[2].1), (2, Data()), (4, addition)] {
                XCTAssertEqual(try reader.read(reader.entries[index]), data)
            }
            try SingleStreamTestSupport.check(source, format: SingleStreamTestSupport.format(format), in: directory, label: "edited")
        }
    }
}
