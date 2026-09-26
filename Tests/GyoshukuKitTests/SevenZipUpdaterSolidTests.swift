import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterSolidTests: XCTestCase {
    func testFollowingPackMovesUpAndDownWithRelocatedAppend() throws {
        let root = try ZipTestSupport.directory("7z-solid-size-changes")
        let tailURL = try SevenZipEditSupport.source(root, count: 1)
        let tail = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(tailURL)))
        let tailBytes = try Data(contentsOf: tailURL)
        for grows in [false, true] {
            let payload = grows ? LHATestSupport.random(65536) : Data(count: 65536)
            let packed = Data([42]) + payload
            var model = SevenZipEditModel()
            model.folders = [.init(coders: [.init(methodID: [0])], bindPairs: [], packedInputs: [0],
                unpackSizes: [UInt64(packed.count)], finalOutput: 0, packIndices: 0..<1, substreamIndices: 0..<2), tail.folders[0]]
            model.folders[1].packIndices = 1..<2; model.folders[1].substreamIndices = 2..<3
            let middle = UInt64(32 + packed.count), end = middle + tail.packs[0].length
            model.packs = [.init(range: 32..<middle), .init(range: middle..<end)]
            model.substreams = [.init(folderIndex: 0, offset: 0, size: 1, crc32: CRC32.checksum(Data([42]))),
                .init(folderIndex: 0, offset: 1, size: UInt64(payload.count), crc32: CRC32.checksum(payload)), tail.substreams[0]]
            model.substreams[2].folderIndex = 1
            model.files = [.init(rawName: SevenZipEditModel.nameBytes("drop"), substreamIndex: 0, isEmptyFile: false),
                .init(rawName: SevenZipEditModel.nameBytes("keep"), substreamIndex: 1, isEmptyFile: false), tail.files[0]]
            // Use a baseline accepted by all three readers. Apple's bsdtar rejects a
            // partially defined WinAttributes vector before any edit, unlike 7zz / KaitoKit.
            for index in 0..<2 {
                model.files[index].attributes = tail.files[0].attributes
                model.files[index].modificationTime = tail.files[0].modificationTime
            }
            model.files[2].substreamIndex = 2; model.mainPackEnd = end
            let header = try SevenZipHeaderSerializer.header(model), range = tail.packs[0].range
            let source = root.appendingPathComponent("source-\(grows).7z")
            try (SevenZipRecords.signature(packedSize: end - 32, header: header) + packed
                + tailBytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) + header).write(to: source)
            try SevenZipExternalOracles.check(source, password: nil)
            for sequential in [false, true] {
                let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                    try SevenZipUpdater.open(url: source, output: output)
                }
                // The append is already on disk before the reencoded folder's new length is known.
                try updater.add(data: Data([1, 9]), as: "added", modificationDate: ZipTestSupport.date)
                try updater.remove(entriesAt: [0])
                var updates: [ArchiveUpdater.CommitProgress] = []
                try updater.commit { updates.append($0) }
                let reader = try SevenZipEditSupport.reader(output)
                let edited = try XCTUnwrap(SevenZipEditModel.read(reader))
                XCTAssertEqual(edited.packs[0].length > model.packs[0].length, grows)
                XCTAssertNotEqual(edited.packs[1].range.lowerBound, model.packs[1].range.lowerBound)
                try SevenZipEditSupport.assertCarried(source, output, originalModel: model, outputModel: edited, pairs: [(1, 1)])
                XCTAssertEqual(try SevenZipEditSupport.items(reader).map(\.data), [payload, Data(count: 1000), Data([1, 9])])
                XCTAssertEqual(updater.lastCommitStrategy, .relocatedAppend)
                XCTAssertEqual(updates.map(\.completedBytes), updates.map(\.completedBytes).sorted())
                XCTAssertTrue(updates.allSatisfy { $0.totalBytes == updates.first!.totalBytes && $0.completedBytes <= $0.totalBytes })
                XCTAssertEqual(updates.last?.completedBytes, updates.last?.totalBytes)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["output.7z"])
                try SevenZipExternalOracles.check(output, password: nil)
            }
        }
    }

    func testS200SizeAgainstSevenZipDelete() throws {
        guard SevenZipExternalOracles.available else { throw XCTSkip("7zz / bsdtar unavailable") }
        let root = try ZipTestSupport.directory("7z-solid-s200-size")
        let source = SevenZipEditSupport.fixture("s200"), reference = root.appendingPathComponent("reference.7z")
        try FileManager.default.copyItem(at: source, to: reference)
        let reader = try SevenZipEditSupport.reader(source)
        let index = try XCTUnwrap(reader.entries.firstIndex { ($0.uncompressedSize ?? 0) > 0 })
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["d", "-y", reference.path, reader.entries[index].name], in: root, log: "7zz-d")
        let output = root.appendingPathComponent("output.7z")
        let updater = try SevenZipUpdater.open(url: source, output: output)
        try updater.remove(entriesAt: [index]); try updater.commit()
        let actualSize = try Data(contentsOf: output).count, referenceSize = try Data(contentsOf: reference).count
        print("7Z-S200\tupdater_bytes=\(actualSize)\t7zz_delete_bytes=\(referenceSize)")
        XCTAssertLessThanOrEqual(Double(actualSize), Double(referenceSize) * 1.05)
        try SevenZipExternalOracles.check(output, password: nil)
    }

    func testSolidReencodingAndAppendInBothModes() throws {
        for name in ["m", "s200", "z_default", "z_aes", "bcj", "bcj2", "ppmd", "lib", "solid_zero"] {
            let root = try ZipTestSupport.directory("7z-solid-" + name)
            let source = SevenZipEditSupport.fixture(name)
            let original = try SevenZipEditSupport.reader(source)
            let model = try XCTUnwrap(SevenZipEditModel.read(original))
            let target = try XCTUnwrap(model.folders.indices.first { model.folders[$0].substreamIndices.count > 1 })
            let remove = try XCTUnwrap(model.filesByFolder[target].first { original.entries[$0].uncompressedSize != 0 })
            let before = try SevenZipEditSupport.items(original)
            var serial: Data?
            for sequential in [false, true] {
                for add in [false, true] {
                    for threads in [1, 8] {
                        let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                        let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                            try SevenZipUpdater.open(url: source, password: "secret", output: output,
                                options: WriterOptions(password: model.folders[target].isEncrypted ? "secret" : nil,
                                    encryptsSevenZipHeaders: model.header.encrypted, compressionThreads: threads))
                        }
                        try updater.remove(entriesAt: [remove])
                        var expected = before; expected.remove(at: remove)
                        if add {
                            try updater.add(data: Data([1, 7, 9]), as: "added", modificationDate: ZipTestSupport.date)
                            expected.append(.init(name: "added", kind: .file, data: Data([1, 7, 9])))
                        }
                        var progress: [ArchiveUpdater.CommitProgress] = []
                        try updater.commit { progress.append($0) }
                        let actual = try SevenZipEditSupport.reader(output)
                        XCTAssertEqual(try SevenZipEditSupport.items(actual), expected, "\(name) seq=\(sequential) add=\(add) threads=\(threads)")
                        let new = try XCTUnwrap(SevenZipEditModel.read(actual))
                        XCTAssertEqual(new.folders[target].packedInputs.count, 1)
                        XCTAssertEqual(new.folders[target].coders.last?.methodID, [0x21])
                        XCTAssertEqual(new.folders[target].substreamIndices.count, model.folders[target].substreamIndices.count - 1)
                        try SevenZipEditSupport.assertCarried(source, output, originalModel: model, outputModel: new,
                            pairs: model.folders.indices.filter { $0 != target }.map { ($0, $0) })
                        XCTAssertEqual(updater.lastCommitStatistics?.reencodedFolderCount, 1)
                        XCTAssertEqual(updater.lastCommitStatistics?.reencodedPackBytes, updater.lastCommitStatistics?.reencodeScratchWrittenBytes)
                        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["output.7z"])
                        XCTAssertEqual(progress.last?.completedBytes, progress.last?.totalBytes)
                        XCTAssertTrue(progress.allSatisfy { $0.totalBytes == progress.first!.totalBytes && $0.completedBytes <= $0.totalBytes })
                        if !model.folders[target].isEncrypted && !model.header.encrypted && !add && !sequential {
                            let bytes = try Data(contentsOf: output)
                            if threads == 1 { serial = bytes } else { XCTAssertEqual(bytes, serial, name) }
                        }
                        if sequential && add { XCTAssertEqual(updater.lastCommitStrategy, .sequential, name) }
                        if name == "solid_zero" {
                            XCTAssertEqual(new.folders[target].unpackSizes.last, 0)
                            XCTAssertEqual(new.packs[new.folders[target].packIndices.lowerBound].length, 1)
                        }
                        try SevenZipExternalOracles.check(output, password: "secret")
                    }
                }
            }
        }
    }
}
