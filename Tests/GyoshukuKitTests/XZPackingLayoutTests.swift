import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import GyoshukuKit

final class XZPackingLayoutTests: XCTestCase {
    func testPublicWriterPackingAndPieceBoundariesMatchXZAndKaitoKit() throws {
        let root = try ZipTestSupport.directory("xz-production-limits")
        let packing = 4 * 1024 * 1024, piece = 16 * 1024 * 1024
        let cases: [(String, [Int], [Int])] = [
            ("small", Array(repeating: 128 * 1024, count: 40), [31 * (128 * 1024 + 512), 9 * (128 * 1024 + 512)]),
            ("medium", [packing + 1], [512, packing + 512]),
            ("large", [piece + 129], [512, piece, 512])
        ]
        let xz = try XCTUnwrap(["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
            .first { FileManager.default.isExecutableFile(atPath: $0) })
        for (name, sizes, expected) in cases {
            let url = root.appendingPathComponent(name + ".tar.xz")
            let writer = try ArchiveWriter.create(url: url, format: .tarXZ, options: WriterOptions(compressionThreads: 4))
            for (index, size) in sizes.enumerated() {
                try writer.add(data: Data(repeating: UInt8(index), count: size), as: "file-\(index)", modificationDate: ZipTestSupport.date)
            }
            try writer.finish()
            let reader = try CompressedTarTestSupport.open(url)
            let map = try XCTUnwrap(reader.tarEditingSnapshot()?.chunkMap)
            let lengths = map.chunks.map { Int($0.imageRange.byteLength) }
            XCTAssertEqual(Array(lengths.dropLast()), expected, name)
            XCTAssertEqual(lengths, try TarChunkLayoutTestSupport.expectedLengths(url, format: .tarXZ,
                limits: .init(packing: packing, piece: piece)))
            for (entry, size) in zip(reader.entries, sizes) { XCTAssertEqual(try reader.read(entry).count, size) }
            let listing = try ZipTestSupport.run(xz, ["--robot", "-lvv", url.path], in: root, log: name + "-blocks")
            let toolLengths = listing.split(separator: "\n").filter { $0.hasPrefix("block\t") }.compactMap {
                Int($0.split(separator: "\t")[7])
            }
            XCTAssertEqual(toolLengths, lengths)
            try ZipTestSupport.run(xz, ["-t", url.path], in: root, log: name + "-test")
        }
    }
}
