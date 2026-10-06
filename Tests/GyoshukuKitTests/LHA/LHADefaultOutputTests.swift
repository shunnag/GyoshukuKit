import Foundation
import XCTest
@testable import GyoshukuKit

final class LHADefaultOutputTests: XCTestCase {
    func testDefaultAndExplicitLH5LevelSixMatchFrozenExistingFixtures() throws {
        let edges: [ExpectedEntry] = [
            .init(name: "empty"), .init(name: "one", data: Data([0x9F])),
            .init(name: "8192", data: Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })),
            .init(name: "100000", data: Data(repeating: 0xEB, count: 100_000))
        ]
        let japanese: [ExpectedEntry] = [
            .init(name: "ascii.txt", data: Data("ASCII control\n".utf8)),
            .init(name: "日本語.txt", data: Data("Japanese\n".utf8)),
            .init(name: "ガラス/①髙～.txt", data: Data([1, 2, 3])),
            .init(name: "dir/sub/file.txt", data: Data(repeating: 0x41, count: 1000))
        ]
        let fixtures: [(String, [ExpectedEntry])] = [
            ("edges", edges), ("japanese", japanese),
            ("repetitive", [.init(name: "repetitive.bin", data: Data(repeating: 0x41, count: 1 << 20))])
        ]
        for (name, items) in fixtures {
            let frozen = try Data(contentsOf: TestPaths.fixture("lha-methods", "lh5-\(name).lzh"))
            for options in [WriterOptions(), .init(lhaMethod: .lh5, lhaLevel: 6, compressionThreads: 1),
                            .init(lhaMethod: .lh5, lhaLevel: 6, compressionThreads: 4)] {
                let directory = try TestSupport.directory("lha-default-\(name)-\(options.resolvedCompressionThreads)")
                let output = directory.appendingPathComponent("archive.lzh")
                let writer = try ArchiveWriter.create(url: output, format: .lha, options: options)
                for item in items {
                    try writer.add(data: item.data, as: item.name.decomposedStringWithCanonicalMapping,
                                   modificationDate: item.date, permissions: item.permissions)
                }
                try writer.finish()
                XCTAssertEqual(try Data(contentsOf: output), frozen, name)
            }
        }
    }
}
