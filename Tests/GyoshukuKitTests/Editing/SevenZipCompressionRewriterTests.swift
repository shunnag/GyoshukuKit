import Foundation
import XCTest
@testable import GyoshukuKit

final class SevenZipCompressionRewriterTests: XCTestCase {
    func testRewriterHonoursSolidFilterAndAESOptions() throws {
        let root = try TestSupport.directory("7z-solid-filter-rewriter"), source = root.appendingPathComponent("source.zip")
        let items: [ExpectedEntry] = [.init(name: "a", data: SevenZipSolidFilterSupport.macho(arm64: true)),
            .init(name: "empty"), .init(name: "b", data: SevenZipSolidFilterSupport.macho(arm64: true))]
        let writer = try ArchiveWriter.create(url: source)
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
        try writer.finish()
        let output = root.appendingPathComponent("output.7z")
        let options = WriterOptions(sevenZipSolid: .on(), sevenZipFilter: .auto, password: "secret", encryptsSevenZipHeaders: true)
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .sevenZip, options: options)
        let added = ExpectedEntry(name: "added", data: SevenZipSolidFilterSupport.macho(arm64: true))
        try rewriter.add(data: added.data, as: added.name, modificationDate: TestSupport.date)
        try rewriter.commit()
        try SevenZipSolidFilterSupport.verify(output, items: items + [added], options: options, blocks: 1, solid: true, filter: "ARM64")
    }

    func testRewriterToSevenZipUsesSelectedMethodForCarriedAndAddedFiles() throws {
        let root = try TestSupport.directory("7z-methods-rewriter")
        let items = SevenZipMethodTestSupport.corpus()
        let source = root.appendingPathComponent("source.zip")
        let writer = try ArchiveWriter.create(url: source)
        for item in items {
            if item.kind == .directory {
                try writer.addDirectory(item.name, modificationDate: TestSupport.date, ownerIDs: nil)
            } else { try writer.add(data: item.data, as: item.name, modificationDate: item.date) }
        }
        try writer.finish()
        for method in SevenZipMethodTestSupport.additionalMethods {
            for mode in 0..<3 {
                let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
                let options = SevenZipMethodTestSupport.options(method, mode: mode)
                let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .sevenZip, options: options)
                let added = ExpectedEntry(name: "追加", data: Data([1, 2, 3]))
                try rewriter.add(data: added.data, as: added.name, modificationDate: added.date)
                try rewriter.commit()
                let after = try SevenZipMethodTestSupport.verify(output, items: items + [added], password: options.password, method: method)
                XCTAssertEqual(after.header.encrypted, mode == 2)
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }
}
