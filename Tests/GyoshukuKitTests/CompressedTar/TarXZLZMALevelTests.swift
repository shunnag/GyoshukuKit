import Foundation
import XCTest
@_spi(TarEditLayout) import KaitoKit
@testable import GyoshukuKit

final class TarXZLZMALevelTests: XCTestCase {
    func testPresetsWithXZTarAndKaitoKitAndTextRatio() throws {
        let directory = try TestSupport.directory("tar-xz-lzma-levels")
        let items = [ExpectedEntry(name: "text.txt", data: LZMAEncoderCorpus.text(size: 384 << 10)), .init(name: "empty")]
        var lengths: [String: Int] = [:]
        for preset in LZMAWriterTestSupport.presets {
            let url = directory.appendingPathComponent(preset.label + ".tar.xz")
            try LZMAWriterTestSupport.write(url, format: .tarXZ,
                options: .init(lzmaLevel: preset.level, lzmaExtreme: preset.extreme, compressionThreads: 4), items: items)
            let bytes = try Data(contentsOf: url)
            lengths[preset.label] = bytes.count
            try LZMAWriterTestSupport.assertXZProperty(bytes, property: preset.property)
            try TestSupport.run(ReferenceTool.xz, ["-t", url.path], in: directory, log: preset.label + "-xz-t")
            let tarName = preset.label + ".tar"
            try ReferenceTool.run(ReferenceTool.xz, ["-dc", url.path], in: directory,
                log: preset.label + "-xz-dc", standardOutput: tarName)
            let extracted = directory.appendingPathComponent(preset.label)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try TestSupport.run(ReferenceTool.tar, ["-xf", directory.appendingPathComponent(tarName).path, "-C", extracted.path],
                in: directory, log: preset.label + "-tar-x")
            for item in items { XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(item.name)), item.data) }
            try TestSupport.assertKaitoKitRoundTrip(url, expected: items)
        }
        XCTAssertLessThan(try XCTUnwrap(lengths["9"]), try XCTUnwrap(lengths["1"]))
    }

    func testUpdaterUsesOwnEncoderForChangedBlocks() throws {
        let directory = try TestSupport.directory("tar-xz-lzma-update")
        let url = directory.appendingPathComponent("archive.tar.xz")
        let items = LZMAWriterTestSupport.items()
        try LZMAWriterTestSupport.write(url, format: .tarXZ, options: .init(), items: items)
        let output = directory.appendingPathComponent("updated.tar.xz")
        let updater = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(url), output: output,
            format: .tarXZ, options: .init(lzmaLevel: 0, compressionThreads: 4))
        let added = ExpectedEntry(name: "added", data: Data(repeating: 0x41, count: 5001))
        try updater.add(data: added.data, as: added.name, modificationDate: TestSupport.date)
        try updater.commit()
        try TestSupport.run(ReferenceTool.xz, ["-t", output.path], in: directory, log: "xz-t")
        try TestSupport.assertKaitoKitRoundTrip(output, expected: items + [added])
    }

    func testLevelNineConcurrencyCapOn128MiBInput() throws {
        let directory = try TestSupport.directory("tar-xz-lzma-memory")
        let options = WriterOptions(lzmaLevel: 9, memoryLimit: 1200 << 20, compressionThreads: 64)
        let configuration = try LZMAWriterConfiguration(options: options)
        XCTAssertEqual(configuration.pieceSize, 192 << 20)
        XCTAssertEqual(configuration.threads, 1)
        XCTAssertLessThanOrEqual(UInt64(configuration.threads) * configuration.memoryPerThread, configuration.memoryBudget)
        XCTAssertEqual(options.maximumPendingInputBytes(for: .tarXZ), UInt64((192 + 4) << 20))
        let url = directory.appendingPathComponent("archive.tar.xz")
        let input = Data(repeating: 0x5A, count: 128 << 20)
        try LZMAWriterTestSupport.write(url, format: .tarXZ, options: options, items: [.init(name: "large", data: input)])
        try TestSupport.run(ReferenceTool.xz, ["-t", url.path], in: directory, log: "xz-t")
        let reader = try CompressedTarTestSupport.open(url)
        XCTAssertEqual(try reader.read(reader.entries[0]), input)
        let map = try XCTUnwrap(reader.tarEditingSnapshot()?.chunkMap)
        XCTAssertTrue(map.chunks.contains { $0.imageRange.byteLength == UInt64(input.count) })
    }
}
