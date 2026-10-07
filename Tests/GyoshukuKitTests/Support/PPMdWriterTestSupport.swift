import Foundation
import XCTest
@testable import GyoshukuKit

enum PPMdWriterTestSupport {
    struct Preset {
        let level: Int
        let zipOrder: Int
        let sevenZipOrder: Int
        let memoryMiB: Int
        let memoryLabel: String
        var override = false

        func options() -> WriterOptions {
            WriterOptions(compressionMethod: .ppmd, sevenZipMethod: .ppmd, ppmdLevel: level,
                ppmdOrder: override ? zipOrder : nil, ppmdMemoryMiB: override ? memoryMiB : nil,
                useCompressionHeuristic: false, compressionThreads: 4)
        }
    }
    // encoder の preset 表から期待値を生成せず、公開する仕様を固定する。
    static let presets: [Preset] = [
        .init(level: 1, zipOrder: 3, sevenZipOrder: 3, memoryMiB: 1, memoryLabel: "20"),
        .init(level: 6, zipOrder: 8, sevenZipOrder: 6, memoryMiB: 16, memoryLabel: "24"),
        .init(level: 9, zipOrder: 16, sevenZipOrder: 16, memoryMiB: 192, memoryLabel: "192m"),
        .init(level: 9, zipOrder: 7, sevenZipOrder: 7, memoryMiB: 3, memoryLabel: "3m", override: true)
    ]

    static func items() -> [ExpectedEntry] {
        [.init(name: "日本語.txt", data: LZMAEncoderCorpus.text(size: 65_537)),
         .init(name: "random.bin", data: TestCorpus.random(32_771)),
         .init(name: "one", data: Data([0xAF])), .init(name: "empty")]
    }

    static func write(_ url: URL, format: ArchiveFormat, options: WriterOptions, items: [ExpectedEntry]) throws {
        let phaseStart = EncoderTestTiming.start()
        defer {
            if EncoderTestTiming.enabled {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                EncoderTestTiming.end("encode.ppmd-writer+io", phaseStart, input: items.reduce(0) { $0 + $1.data.count }, output: size)
            }
        }
        let writer = try ArchiveWriter.create(url: url, format: format, options: options)
        for item in items {
            if item.kind == .directory { try writer.addDirectory(item.name, modificationDate: TestSupport.date, ownerIDs: nil) }
            else { try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.permissions) }
        }
        try writer.finish()
    }

    /// 必須の7zz t / l / x と KaitoKit の全 byte 往復。ZIP の一覧は order / memory を省略する。
    @discardableResult
    static func verify(_ url: URL, items: [ExpectedEntry], password: String? = nil, metadata: Bool = true) throws -> String {
        try LZMAWriterTestSupport.verify(url, items: items, password: password, metadata: metadata)
    }

    static func coderProperties(order: Int, memoryMiB: Int) -> [UInt8] {
        let memory = UInt32(memoryMiB) << 20
        return [UInt8(order)] + (0..<4).map { UInt8(truncatingIfNeeded: memory >> ($0 * 8)) }
    }
}
