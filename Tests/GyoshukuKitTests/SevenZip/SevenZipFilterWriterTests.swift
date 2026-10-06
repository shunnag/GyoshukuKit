import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipFilterWriterTests: XCTestCase {
    func testOwnLZMA2SolidFiltersAndAES() throws {
        let root = try TestSupport.directory("7z-filters-own-lzma2")
        for (filter, name) in [(SevenZipFilterMode.bcjX86, "BCJ"), (.arm64, "ARM64"), (.delta(distance: 4), "Delta:4")] {
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
            let payload = SevenZipSolidFilterSupport.macho(arm64: filter == .arm64)
            let items: [ExpectedEntry] = [.init(name: "a", data: payload), .init(name: "b", data: payload.prefix(8193))]
            let options = WriterOptions(sevenZipSolid: .on(), sevenZipFilter: filter, lzmaLevel: 1,
                password: "secret", encryptsSevenZipHeaders: true, compressionThreads: 2)
            try SevenZipMethodTestSupport.write(url, items: items, options: options)
            try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true, filter: name)
        }
    }

    func testForwardBytesMatchSevenZip() throws {
        let root = try TestSupport.directory("7z-filter-forward-bytes")
        for (mode, name, arm64) in [(SevenZipFilterMode.bcjX86, "BCJ", false), (.arm64, "ARM64", true), (.delta(distance: 4), "Delta:4", false)] {
            let work = try TestSupport.work(in: root), input = work.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            let payload = SevenZipSolidFilterSupport.macho(arm64: arm64, size: 262_149) + TestCorpus.random(262_149)
            try payload.write(to: input.appendingPathComponent("payload"))
            let reference = work.appendingPathComponent("reference.7z"), output = work.appendingPathComponent("output.7z")
            try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-t7z", "-m0=" + name, "-m1=Copy", "-ms=off", "-mhc=off", reference.path, "payload"],
                in: work, log: "7zz-a", workingDirectory: input)
            let options = WriterOptions(sevenZipMethod: .copy, sevenZipFilter: mode)
            let items: [ExpectedEntry] = [.init(name: "payload", data: payload)]
            try SevenZipMethodTestSupport.write(output, items: items, options: options)
            let actual = try SevenZipSolidFilterSupport.verify(output, items: items, options: options, blocks: 1, solid: false, filter: name)
            let expected = try SevenZipMethodTestSupport.verify(reference, items: items, password: nil, metadata: false)
            func packed(_ url: URL, model: SevenZipEditModel) throws -> Data {
                let bytes = try Data(contentsOf: url), range = try XCTUnwrap(model.packs.first).range
                return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            }
            XCTAssertEqual(try packed(output, model: actual), try packed(reference, model: expected), name)
        }
    }

    func testFiltersEveryMethodAndSolidAES() throws {
        let root = try TestSupport.directory("7z-filters-methods")
        let filters: [(SevenZipFilterMode, String, Data, [UInt8])] = [
            (.bcjX86, "BCJ", SevenZipSolidFilterSupport.macho(arm64: false), [3, 3, 1, 3]),
            (.arm64, "ARM64", SevenZipSolidFilterSupport.macho(arm64: true), [0x0A]),
            (.delta(distance: 4), "Delta:4", TestCorpus.random(32_769), [3])]
        for (filter, name, payload, id) in filters {
            for method in [SevenZipCompressionMethod.lzma2, .lzma, .deflate, .bzip2, .copy] {
                for solid in [false, true] {
                    let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
                    let options = WriterOptions(sevenZipMethod: method, sevenZipSolid: solid ? .on() : .off,
                        sevenZipFilter: filter, lzmaLevel: method == .lzma ? 1 : nil,
                        password: solid ? "secret" : nil, encryptsSevenZipHeaders: solid, compressionThreads: 2)
                    let items: [ExpectedEntry] = [.init(name: "first", data: payload), .init(name: "empty"),
                        .init(name: "second", data: payload.prefix(8195))]
                    try SevenZipMethodTestSupport.write(url, items: items, options: options)
                    let model = try SevenZipSolidFilterSupport.verify(url, items: items, options: options,
                        blocks: solid ? 1 : 2, solid: solid, filter: name)
                    for folder in model.folders {
                        XCTAssertEqual(folder.coders.last?.methodID, id)
                        XCTAssertEqual(folder.bindPairs, (1..<folder.coders.count).map { .init(input: $0, output: $0 - 1) })
                        XCTAssertEqual(folder.unpackSizes.suffix(2), [folder.size, folder.size])
                    }
                }
            }
        }
    }

    func testDeltaExtremeDistancesAndSmallChunks() throws {
        let root = try TestSupport.directory("7z-filter-delta-distances")
        for distance in [1, 256] {
            let url = root.appendingPathComponent("\(distance).7z")
            let options = WriterOptions(sevenZipMethod: .copy, sevenZipSolid: .on(), sevenZipFilter: .delta(distance: distance))
            let items: [ExpectedEntry] = [.init(name: "a", data: TestCorpus.random(13)), .init(name: "b", data: TestCorpus.random(519))]
            try SevenZipMethodTestSupport.write(url, items: items, options: options)
            try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true, filter: "Delta:\(distance)")
        }
    }

    func testAutoSplitsByDetectedClassAndRejectsUniversal() throws {
        let root = try TestSupport.directory("7z-filter-auto")
        func pe(_ machine: UInt16) -> Data {
            var data = Data(count: 128)
            data[0] = 0x4D; data[1] = 0x5A; data[60] = 64
            data[64] = 0x50; data[65] = 0x45
            data[68] = UInt8(truncatingIfNeeded: machine); data[69] = UInt8(machine >> 8)
            return data
        }
        var elf = Data(count: 64)
        elf.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1]); elf[18] = 183
        var universal = Data(count: 32)
        universal.replaceSubrange(0..<4, with: [0xCA, 0xFE, 0xBA, 0xBE])
        let items: [ExpectedEntry] = [.init(name: "x86-macho", data: SevenZipSolidFilterSupport.macho(arm64: false)),
            .init(name: "x86-pe", data: pe(0x8664)), .init(name: "x86-32-pe", data: pe(0x14C)),
            .init(name: "empty"), .init(name: "arm-macho", data: SevenZipSolidFilterSupport.macho(arm64: true)),
            .init(name: "arm-pe", data: pe(0xAA64)), .init(name: "arm-elf", data: elf),
            .init(name: "plain", data: Data("text file with no executable header".utf8)), .init(name: "universal", data: universal)]
        for solid in [false, true] {
            let url = root.appendingPathComponent("\(solid).7z")
            let options = WriterOptions(sevenZipMethod: .copy, sevenZipSolid: solid ? .on() : .off, sevenZipFilter: .auto)
            try SevenZipMethodTestSupport.write(url, items: items, options: options)
            let model = try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: solid ? 3 : 8, solid: solid)
            XCTAssertEqual(model.folders.map { $0.coders.last!.methodID }, solid
                ? [[3, 3, 1, 3], [0x0A], [0]] : [[3, 3, 1, 3], [3, 3, 1, 3], [3, 3, 1, 3], [0x0A], [0x0A], [0x0A], [0], [0]])
        }
    }

    func testReverseSevenZipSolidFilters() throws {
        let root = try TestSupport.directory("7z-filter-reverse"), input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for (filter, arm64) in [("BCJ", false), ("ARM64", true), ("Delta:4", false)] {
            let items: [ExpectedEntry] = [.init(name: "a", data: SevenZipSolidFilterSupport.macho(arm64: arm64)),
                .init(name: "b", data: TestCorpus.random(8195))]
            for item in items { try item.data.write(to: input.appendingPathComponent(item.name)) }
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
            try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-t7z", "-ms=on", "-mf=" + filter, "-mhc=off", url.path, "a", "b"],
                in: work, log: "7zz-a", workingDirectory: input)
            let model = try SevenZipMethodTestSupport.verify(url, items: items, password: nil, ordered: false, metadata: false)
            XCTAssertEqual(model.folders.count, 1)
            let id: [UInt8] = filter == "BCJ" ? [3, 3, 1, 3] : filter == "ARM64" ? [0x0A] : [3]
            XCTAssertTrue(model.folders[0].coders.contains { $0.methodID == id })
        }
    }

    func testARM64ReducesRealBinaryCorpus() throws {
        let root = try TestSupport.directory("7z-arm64-real-binaries")
        func arm64Slice(_ url: URL) throws -> Data {
            let data = try Data(contentsOf: url)
            let b = Array(data)
            func be32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
            if be32(0) == 0xCAFE_BABE {
                for index in 0..<Int(be32(4)) {
                    let i = 8 + index * 20
                    if be32(i) == 0x0100_000C {
                        let offset = Int(be32(i + 8)), size = Int(be32(i + 12))
                        return data.subdata(in: offset..<(offset + size))
                    }
                }
                throw CocoaError(.fileReadCorruptFile)
            }
            XCTAssertEqual(data.uint32LE(at: 4), 0x0100_000C, url.path)
            return data
        }
        let items = try ["/usr/lib/dyld", "/usr/bin/ditto", "/usr/bin/git"].map { path in
            ExpectedEntry(name: URL(fileURLWithPath: path).lastPathComponent, data: try arm64Slice(URL(fileURLWithPath: path)))
        }
        var sizes: [UInt64] = []
        for filter in [SevenZipFilterMode.none, .arm64] {
            let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive.7z")
            let options = WriterOptions(sevenZipSolid: .on(), sevenZipFilter: filter, compressionThreads: 2)
            try SevenZipMethodTestSupport.write(url, items: items, options: options)
            let model = try SevenZipSolidFilterSupport.verify(url, items: items, options: options, blocks: 1, solid: true,
                filter: filter == .none ? nil : "ARM64")
            sizes.append(model.packs.reduce(0) { $0 + $1.length })
        }
        TestSupport.report("7Z ARM64 real corpus: none=\(sizes[0]), ARM64=\(sizes[1])")
        XCTAssertLessThan(sizes[1], sizes[0])
    }
}
