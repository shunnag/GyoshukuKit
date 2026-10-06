import Foundation
import XCTest
@testable import GyoshukuKit

final class SevenZipCompressionRewriterTests: XCTestCase {
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
