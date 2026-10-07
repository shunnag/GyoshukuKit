import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipPPMdWriterTests: XCTestCase {
    func testPresetsWithAESAndHeaderEncryption() throws {
        let root = try TestSupport.directory("7z-ppmd-levels")
        let items = PPMdWriterTestSupport.items()
        for preset in PPMdWriterTestSupport.presets {
            for mode in 0..<3 {
                let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
                var options = preset.options()
                options.password = mode == 0 ? nil : "secret"
                options.encryptsSevenZipHeaders = mode == 2
                try PPMdWriterTestSupport.write(url, format: .sevenZip, options: options, items: items)
                let listing = try PPMdWriterTestSupport.verify(url, items: items, password: options.password)
                for entry in SevenZipTestSupport.listingEntries(listing) where entry["Size"] != "0" {
                    let method = entry["Method"] ?? ""
                    XCTAssertTrue(method.contains("PPMD:o\(preset.sevenZipOrder):mem\(preset.memoryLabel)"), method)
                    XCTAssertEqual(method.contains("7zAES:"), mode > 0)
                }
                let model = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(url, password: options.password)))
                XCTAssertEqual(model.header.encrypted, mode == 2)
                XCTAssertEqual(model.folders.count, items.filter { !$0.data.isEmpty }.count)
                for folder in model.folders {
                    XCTAssertEqual(folder.coders.map(\.methodID), (mode > 0 ? [[6, 0xF1, 7, 1]] : []) + [[3, 4, 1]])
                    XCTAssertEqual(folder.coders.last?.properties,
                        PPMdWriterTestSupport.coderProperties(order: preset.sevenZipOrder, memoryMiB: preset.memoryMiB))
                    XCTAssertEqual(folder.bindPairs, mode > 0 ? [.init(input: 1, output: 0)] : [])
                }
            }
        }
    }

    func testDefaultPresetAndReverseSevenZipToolArchive() throws {
        let root = try TestSupport.directory("7z-ppmd-default-reverse")
        let items = [ExpectedEntry(name: "text.txt", data: LZMAEncoderCorpus.text(size: 65_537))]
        let a = root.appendingPathComponent("default.7z"), b = root.appendingPathComponent("six.7z")
        try PPMdWriterTestSupport.write(a, format: .sevenZip, options: .init(sevenZipMethod: .ppmd), items: items)
        try PPMdWriterTestSupport.write(b, format: .sevenZip, options: .init(sevenZipMethod: .ppmd, ppmdLevel: 6), items: items)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        _ = try PPMdWriterTestSupport.verify(a, items: items)
        try items[0].data.write(to: root.appendingPathComponent(items[0].name))
        let reverse = root.appendingPathComponent("reference.7z")
        try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-t7z", "-m0=PPMd", reverse.path, items[0].name],
            in: root, log: "7zz-a", workingDirectory: root)
        _ = try PPMdWriterTestSupport.verify(reverse, items: items, metadata: false)
        let model = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(reverse, password: nil)))
        XCTAssertEqual(model.folders[0].coders.last?.methodID, [3, 4, 1])
    }

    func testSolidFiltersAndEncryption() throws { try verifySolidFilters(large: false) }

    func testSolidFiltersAndEncryptionFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifySolidFilters(large: true)
    }

    private func verifySolidFilters(large: Bool) throws {
        let root = try TestSupport.directory("7z-ppmd-solid-filters")
        for (filter, label, arm64, id) in [(SevenZipFilterMode.none, "", false, [UInt8]()),
            (.bcjX86, "BCJ", false, [3, 3, 1, 3]), (.arm64, "ARM64", true, [10]),
            (.delta(distance: 4), "Delta:4", false, [3])] {
            let items: [ExpectedEntry] = [.init(name: "one", data: SevenZipSolidFilterSupport.macho(arm64: arm64, size: large ? 32_769 : 4097, alternatingBranches: !large)),
                .init(name: "empty"), .init(name: "two", data: SevenZipSolidFilterSupport.macho(arm64: arm64, size: large ? 262_149 : 8197, alternatingBranches: !large))]
            if !large && (label == "BCJ" || label == "ARM64") {
                let data = items[0].data
                let positions = stride(from: 32, through: data.count - 8, by: 8)
                let signs = Set(positions.map { data[$0 + (arm64 ? 3 : 4)] & (arm64 ? 2 : 0x80) })
                XCTAssertEqual(signs, arm64 ? Set([UInt8(0), 2]) : Set([UInt8(0), 0x80]))
                if arm64 {
                    // ADRP の 21-bit immediate の符号も両方を含む。
                    XCTAssertEqual(Set(positions.map { data[$0 + 6] & 0x80 }), Set([UInt8(0), 0x80]))
                }
            }
            for solid in [false, true] {
                for encrypted in [false, true] {
                    let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
                    let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: solid ? .on() : .off,
                        sevenZipFilter: filter, ppmdOrder: 7, ppmdMemoryMiB: 3,
                        password: encrypted ? "secret" : nil, encryptsSevenZipHeaders: encrypted, compressionThreads: 4)
                    try PPMdWriterTestSupport.write(url, format: .sevenZip, options: options, items: items)
                    let model = try SevenZipSolidFilterSupport.verify(url, items: items, options: options,
                        blocks: solid ? 1 : 2, solid: solid, filter: label.isEmpty ? nil : label)
                    for folder in model.folders {
                        let expected = (encrypted ? [[UInt8(6), 0xF1, 7, 1]] : []) + [[3, 4, 1]] + (id.isEmpty ? [] : [id])
                        XCTAssertEqual(folder.coders.map(\.methodID), expected)
                        XCTAssertEqual(folder.coders.first { $0.methodID == [3, 4, 1] }?.properties, [7, 0, 0, 0x30, 0])
                    }
                }
            }
        }
    }

    func testUpdaterSolidReencodeAndAdditionsAndRewriter() throws {
        let root = try TestSupport.directory("7z-ppmd-edit")
        let items: [ExpectedEntry] = [.init(name: "drop", data: Data([1, 2, 3])),
            .init(name: "keep-a", data: SevenZipSolidFilterSupport.macho(arm64: true)),
            .init(name: "keep-b", data: TestCorpus.random(4099))]
        let added = [ExpectedEntry(name: "added-a", data: Data([7, 8])), .init(name: "added-b", data: Data([9, 10]))]
        for encrypted in [false, true] {
            let work = try TestSupport.work(in: root), source = work.appendingPathComponent("source.7z")
            let sourceOptions = WriterOptions(sevenZipSolid: .on(), sevenZipFilter: .arm64,
                password: encrypted ? "secret" : nil, encryptsSevenZipHeaders: encrypted)
            try PPMdWriterTestSupport.write(source, format: .sevenZip, options: sourceOptions, items: items)
            let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(), sevenZipFilter: .delta(distance: 4),
                ppmdOrder: 7, ppmdMemoryMiB: 3, password: sourceOptions.password, encryptsSevenZipHeaders: encrypted)
            let output = work.appendingPathComponent("updated.7z")
            let updater = try SevenZipUpdater.open(url: source, password: options.password, output: output, options: options)
            try updater.remove(entriesAt: [0])
            for item in added { try updater.add(data: item.data, as: item.name, modificationDate: item.date) }
            try updater.commit()
            let expected = Array(items.dropFirst()) + added
            let model = try SevenZipSolidFilterSupport.verify(output, items: expected, options: options, blocks: 2, solid: true)
            for folder in model.folders {
                XCTAssertEqual(folder.coders.first { $0.methodID == [3, 4, 1] }?.properties, [7, 0, 0, 0x30, 0])
            }
            XCTAssertEqual(model.folders[0].coders.last?.methodID, [10])
            XCTAssertEqual(model.folders[1].coders.last?.methodID, [3])
            let rewritten = work.appendingPathComponent("rewritten.7z")
            let rewriter = try ArchiveRewriter.open(url: output, password: options.password, output: rewritten, format: .sevenZip, options: options)
            try rewriter.commit()
            let after = try SevenZipSolidFilterSupport.verify(rewritten, items: expected, options: options, blocks: 1, solid: true, filter: "Delta:4")
            XCTAssertEqual(after.folders[0].coders.first { $0.methodID == [3, 4, 1] }?.properties, [7, 0, 0, 0x30, 0])
        }
    }

    func testTwentyMiBTextWithSmallMemoryKeepsOneStream() throws { try verifyRestarts(large: false) }

    func testTwentyMiBTextWithSmallMemoryKeepsOneStreamFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyRestarts(large: true)
    }

    private func verifyRestarts(large: Bool) throws {
        let root = try TestSupport.directory("7z-ppmd-restarts")
        let items = [ExpectedEntry(name: "large.txt", data: large ? EncoderTestCorpus.sourceTwentyMiB : EncoderTestCorpus.restoration),
            .init(name: "tail", data: Data([3, 4, 5]))]
        // 複数の IO read / write の後でも一つの model と stream を保つ。
        XCTAssertGreaterThan(items[0].data.count, IOChunk.size)
        var baseline: Data?
        for threads in [1, 4] {
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
            let options = WriterOptions(sevenZipMethod: .ppmd, sevenZipSolid: .on(), ppmdOrder: 6, ppmdMemoryMiB: 1, compressionThreads: threads)
            try PPMdWriterTestSupport.write(url, format: .sevenZip, options: options, items: items)
            let bytes = try Data(contentsOf: url)
            if let baseline {
                // 全 bytes が同じなら、先に行った t / l / x・KaitoKit の検証も同じ結果になる。
                XCTAssertEqual(bytes, baseline)
            } else {
                baseline = bytes
                _ = try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true, filter: "PPMD:o6:mem20")
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }
}
