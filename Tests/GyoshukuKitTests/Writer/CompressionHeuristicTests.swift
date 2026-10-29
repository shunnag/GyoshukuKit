import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class CompressionHeuristicTests: XCTestCase {
    private let payload = Data(repeating: 65, count: 131_073)

    private func verify(_ url: URL, items: [ExpectedEntry], password: String? = nil) throws {
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items, password: password)
        try TestSupport.run(ReferenceTool.sevenZip, ["t", url.path] + (password.map { ["-p" + $0] } ?? []),
                            in: url.deletingLastPathComponent(), log: url.lastPathComponent + "-7zz")
    }

    func testZIPNewCompressedExtensionsAndOptOut() throws {
        let root = try TestSupport.directory("r2-zip-heuristic")
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = ["avif", "jxl", "heif", "jp2", "cbz", "cbr", "cb7", "epub", "zst", "lz4", "lzma", "tgz", "txz",
                          "m4a", "aac", "flac", "ogg", "opus", "webm", "mkv", "m4v", "docx", "xlsx", "pptx"]
        let items = extensions.map { ExpectedEntry(name: "page." + $0.uppercased(), data: payload) }
        for heuristic in [false, true] {
            let url = root.appendingPathComponent("\(heuristic).zip")
            let writer = try ArchiveWriter.create(url: url, options: .init(useCompressionHeuristic: heuristic))
            for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
            try writer.finish()
            let reader = try ArchiveReader.open(url: url)
            let bytes = ZipBytes(data: try Data(contentsOf: url))
            XCTAssertEqual(reader.entries.count, extensions.count)
            var offset = bytes.central
            for _ in extensions {
                XCTAssertEqual(bytes.u16(offset + 10), heuristic ? 0 : 8)
                offset += 46 + Int(bytes.u16(offset + 28)) + Int(bytes.u16(offset + 30)) + Int(bytes.u16(offset + 32))
            }
            try verify(url, items: items)
        }
    }

    func testSevenZipMixedSolidCopyFoldersAndExplicitOptions() throws {
        let root = try TestSupport.directory("r2-7z-heuristic")
        defer { try? FileManager.default.removeItem(at: root) }
        let items: [ExpectedEntry] = [.init(name: "a.txt", data: payload), .init(name: "b.JPG", data: payload),
            .init(name: "c.avif", data: payload), .init(name: "d.txt", data: payload)]
        for solid in [false, true] {
            for mode in 0..<8 {
                var baseline: Data?
                for threads in [1, 4] {
                    var options = WriterOptions(sevenZipSolid: solid ? .on() : .off, compressionThreads: threads)
                    switch mode {
                    case 1: options.useCompressionHeuristic = false
                    case 2: options = WriterOptions(sevenZipMethod: .lzma2, sevenZipSolid: solid ? .on() : .off, compressionThreads: threads)
                    case 3: options.sevenZipMethod = .lzma2
                    case 4: options.lzmaLevel = 1
                    case 5: options.password = "secret"; options.encryptsSevenZipHeaders = true
                    case 6: options.sevenZipFilter = .auto
                    case 7: options.lzmaExtreme = true
                    default: break
                    }
                    let url = root.appendingPathComponent("\(solid)-\(mode)-\(threads).7z")
                    let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: options)
                    for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                    try writer.finish()
                    let reader = try SevenZipEditSupport.reader(url, password: options.password)
                    let model = try XCTUnwrap(SevenZipEditModel.read(reader))
                    let coders = model.folders.map { $0.coders.filter { !$0.isAES }.map(\.methodID) }
                    if mode == 0 || mode == 5 {
                        XCTAssertTrue(coders.contains([[0]]))
                        XCTAssertTrue(coders.contains([[0x21]]))
                        XCTAssertEqual(model.folders.count, solid ? 3 : 4)
                    } else { XCTAssertTrue(coders.allSatisfy { $0 == [[0x21]] }) }
                    try verify(url, items: items, password: options.password)
                    if mode != 5 {
                        let bytes = try Data(contentsOf: url)
                        if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
                    }
                }
            }
        }
    }

    func testTarXZMixedMembersRespectLevelAndOptOut() throws {
        let root = try TestSupport.directory("r2-xz-heuristic")
        defer { try? FileManager.default.removeItem(at: root) }
        let items: [ExpectedEntry] = [.init(name: "a.txt", data: payload), .init(name: "b.png", data: payload),
            .init(name: "c.txt", data: payload), .init(name: "d.webp", data: Data(payload.prefix(65_536)))]
        for mode in 0..<3 {
            var baseline: Data?
            for threads in [1, 4] {
                let url = root.appendingPathComponent("\(mode)-\(threads).tar.xz")
                let writer = try ArchiveWriter.create(url: url, format: .tarXZ,
                    options: .init(lzmaLevel: mode == 2 ? 1 : nil, useCompressionHeuristic: mode != 1, compressionThreads: threads))
                for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                try writer.finish()
                try verify(url, items: items)
                let bytes = try Data(contentsOf: url)
                XCTAssertEqual(bytes.count > payload.count, mode == 0)
                if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
            }
        }
    }

    func testTarXZLargeStoredMemberAndEmptyCompressedNames() throws {
        let root = try TestSupport.directory("r2-xz-large-heuristic")
        defer { try? FileManager.default.removeItem(at: root) }
        let items: [ExpectedEntry] = [.init(name: "before.txt", data: payload),
            .init(name: "large.avif", data: Data(repeating: 99, count: (4 << 20) + 17)),
            .init(name: "empty.png"), .init(name: "after.txt", data: payload)]
        let url = root.appendingPathComponent("large.tar.xz")
        let writer = try ArchiveWriter.create(url: url, format: .tarXZ)
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
        try writer.finish()
        try verify(url, items: items)
    }

    func testMixedArchivesSurviveUpdaterAndRewriterWithHeuristicOnAndOff() throws {
        let root = try TestSupport.directory("r2-heuristic-edits")
        defer { try? FileManager.default.removeItem(at: root) }
        let original: [ExpectedEntry] = [.init(name: "a.txt", data: payload), .init(name: "b.jpg", data: payload),
            .init(name: "c.avif", data: payload), .init(name: "d.txt", data: payload)]
        let added = ExpectedEntry(name: "new.webp", data: payload)
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tarXZ] {
            for enabled in [true, false] {
                let suffix = format == .sevenZip ? "7z" : "tar.xz"
                let source = root.appendingPathComponent("source-\(enabled)." + suffix)
                let writer = try ArchiveWriter.create(url: source, format: format, options: .init(sevenZipSolid: .on()))
                for item in original { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                try writer.finish()
                try verify(source, items: original)
                let output = root.appendingPathComponent("updated-\(enabled)." + suffix)
                let options = WriterOptions(sevenZipSolid: .on(), useCompressionHeuristic: enabled)
                if format == .sevenZip {
                    let updater = try SevenZipUpdater.open(url: source, output: output, options: options)
                    try updater.remove(entriesAt: [1])
                    try updater.add(data: added.data, as: added.name, modificationDate: TestSupport.date)
                    try updater.commit()
                } else {
                    let updater = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source),
                                                               output: output, format: format, options: options)
                    try updater.remove(entriesAt: [1])
                    try updater.add(data: added.data, as: added.name, modificationDate: TestSupport.date)
                    try updater.commit()
                }
                let expected = [original[0], original[2], original[3], added]
                try verify(output, items: expected)
                let rewritten = root.appendingPathComponent("rewritten-\(enabled)." + suffix)
                let rewriter = try ArchiveRewriter.open(url: output, output: rewritten, format: format, options: options)
                try rewriter.commit()
                try verify(rewritten, items: expected)
            }
        }
    }
}
