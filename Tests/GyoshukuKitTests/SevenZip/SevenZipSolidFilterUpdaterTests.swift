import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipSolidFilterUpdaterTests: XCTestCase {
    func testCarrySolidFoldersAndAppendAccordingToOptions() throws {
        let root = try TestSupport.directory("7z-solid-filter-append")
        let items: [ExpectedEntry] = [.init(name: "one", data: SevenZipSolidFilterSupport.macho(arm64: true)),
            .init(name: "two", data: SevenZipSolidFilterSupport.macho(arm64: true))]
        for encrypted in [false, true] {
            let sourceWork = try TestSupport.work(in: root), source = sourceWork.appendingPathComponent("source.7z")
            let originalOptions = WriterOptions(sevenZipSolid: .on(), sevenZipFilter: .arm64,
                password: encrypted ? "secret" : nil, encryptsSevenZipHeaders: encrypted)
            try SevenZipMethodTestSupport.write(source, items: items, options: originalOptions)
            let before = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(source, password: originalOptions.password)))
            for solid in [false, true] {
                for sequential in [false, true] {
                    let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
                    let options = WriterOptions(sevenZipMethod: .deflate, sevenZipSolid: solid ? .on() : .off,
                        sevenZipFilter: .delta(distance: 4), password: originalOptions.password, encryptsSevenZipHeaders: encrypted)
                    let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                        try SevenZipUpdater.open(url: source, password: originalOptions.password, output: output, options: options)
                    }
                    let added: [ExpectedEntry] = [.init(name: "added-empty"), .init(name: "added-a", data: Data([1, 2, 3])),
                        .init(name: "middle-empty"), .init(name: "added-b", data: TestCorpus.random(521)), .init(name: "last-empty")]
                    for item in added { try updater.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                    try updater.finishAdditions(progress: { update in XCTAssertLessThanOrEqual(update.completedBytes, update.totalBytes) })
                    try updater.commit()
                    let after = try SevenZipSolidFilterSupport.verify(output, items: items + added, options: options,
                        blocks: solid ? 2 : 3, solid: true)
                    try SevenZipEditSupport.assertCarried(source, output, originalModel: before, outputModel: after, pairs: [(0, 0)])
                    for folder in after.folders.dropFirst() { XCTAssertEqual(folder.coders.last?.methodID, [3]) }
                }
            }
        }
    }

    func testDeletionKeepsOriginalFilterIncludingStartOffset() throws {
        let root = try TestSupport.directory("7z-solid-filter-delete")
        // 7zz の BCJ coder は properties を受け付けない。開始位置の保持は ARM64 で照合する。
        for (filter, arm64) in [(SevenZipWriteFilter.x86(0), false), (.arm64(0x1FFF_F000), true), (.delta(256), false)] {
            let work = try TestSupport.work(in: root), source = work.appendingPathComponent("source.7z")
            let items: [ExpectedEntry] = [.init(name: "drop", data: SevenZipSolidFilterSupport.macho(arm64: arm64, size: 101)),
                .init(name: "keep-a", data: SevenZipSolidFilterSupport.macho(arm64: arm64)),
                .init(name: "keep-b", data: TestCorpus.random(4099))]
            let raw = items.reduce(into: Data()) { $0.append($1.data) }
            var cursor = 0, packed = Data()
            let encoder = try SevenZipFolderEncoder.encode(size: UInt64(raw.count), options: WriterOptions(sevenZipMethod: .copy),
                chunkSize: 31, aes: nil, filter: filter, read: { count in
                    let end = min(raw.count, cursor + min(count, 7))
                    defer { cursor = end }
                    return raw.subdata(in: cursor..<end)
                }, write: { packed.append($0) })
            var model = SevenZipEditModel(), offset: UInt64 = 0
            model.folders = [encoder.folder(size: UInt64(raw.count), substreamCount: items.count)]
            model.packs = [.init(range: 32..<(32 + UInt64(packed.count)))]; model.mainPackEnd = model.packs[0].range.upperBound
            for (index, item) in items.enumerated() {
                model.substreams.append(.init(folderIndex: 0, offset: offset, size: UInt64(item.data.count), crc32: CRC32.checksum(item.data)))
                offset += UInt64(item.data.count)
                model.files.append(.init(rawName: SevenZipEditModel.nameBytes(item.name), substreamIndex: index, isEmptyFile: false,
                    modificationTime: try SevenZipRecords.timestamp(TestSupport.date), attributes: 0o100644 << 16 | 0x8020))
            }
            let header = try SevenZipHeaderSerializer.header(model)
            try (SevenZipRecords.signature(packedSize: UInt64(packed.count), header: header) + packed + header).write(to: source)
            try SevenZipSolidFilterSupport.verify(source, items: items, options: .init(), blocks: 1, solid: true)
            for encrypted in [false, true] {
                let outputWork = try TestSupport.work(in: work), output = outputWork.appendingPathComponent("output.7z")
                let options = WriterOptions(sevenZipMethod: .lzma2, sevenZipSolid: .on(), sevenZipFilter: .none,
                    password: encrypted ? "new" : nil, encryptsSevenZipHeaders: encrypted)
                let updater = try SevenZipUpdater.open(url: source, output: output, options: options)
                try updater.remove(entriesAt: [0])
                let added: [ExpectedEntry] = [.init(name: "new-a", data: Data([1, 2, 3])), .init(name: "new-b", data: Data([4, 5, 6]))]
                for item in added { try updater.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                if encrypted { try updater.reencryptExistingEntries(currentPassword: nil) }
                try updater.commit()
                let after = try SevenZipSolidFilterSupport.verify(output, items: Array(items.dropFirst()) + added, options: options, blocks: 2, solid: true)
                XCTAssertEqual(after.folders[0].coders.last, filter.coder)
                XCTAssertEqual(after.folders[1].coders.last?.methodID, [0x21])
            }
        }
    }
}
