import Darwin
import Foundation
import Synchronization
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipScratchResourceTests: XCTestCase {
    /// 300 個の solid folder を持つ極小書庫を作り、各 folder の片方を削除する。
    /// 実ファイルを使わず、通常の 256 FD 制限でも全 folder を保存できること。
    func testHundredsOfReencodingsUseBoundedScratchDescriptors() throws {
        let root = try TestSupport.directory("7z-many-scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.7z")
        var model = SevenZipEditModel(), packed = Data()
        let count = 300
        for index in 0..<count {
            let offset = UInt64(32 + packed.count)
            let bytes = Data([UInt8(truncatingIfNeeded: index), UInt8(truncatingIfNeeded: index + 1)])
            packed.append(bytes)
            model.folders.append(.init(coders: [.init(methodID: [0])], bindPairs: [], packedInputs: [0],
                unpackSizes: [2], finalOutput: 0, packIndices: index..<(index + 1), substreamIndices: (index * 2)..<(index * 2 + 2)))
            model.packs.append(.init(range: offset..<(offset + 2)))
            for item in 0..<2 {
                let stream = index * 2 + item
                model.substreams.append(.init(folderIndex: index, offset: UInt64(item), size: 1,
                    crc32: CRC32.checksum(Data([bytes[item]]))))
                model.files.append(.init(rawName: SevenZipEditModel.nameBytes("file-\(stream)"),
                    substreamIndex: stream, isEmptyFile: false))
            }
        }
        model.mainPackEnd = UInt64(32 + packed.count)
        let header = try SevenZipHeaderSerializer.header(model)
        let original = SevenZipRecords.signature(packedSize: UInt64(packed.count), header: header) + packed + header
        try original.write(to: source)
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        var limited = saved
        limited.rlim_cur = min(saved.rlim_cur, 256)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }
        let output = root.appendingPathComponent("edited.7z")
        let updater = try SevenZipUpdater.open(url: source, output: output,
            options: WriterOptions(lzmaLevel: 0, compressionThreads: 1))
        try updater.remove(entriesAt: Array(stride(from: 0, to: count * 2, by: 2)))
        let scratchCount = Mutex(0)
        try ScratchFile.$testingCreated.withValue({ _ in scratchCount.withLock { $0 += 1 } }) {
            try updater.commit()
        }
        XCTAssertLessThanOrEqual(scratchCount.withLock { $0 }, 2)
        let reader = try SevenZipEditSupport.reader(output, password: nil)
        XCTAssertEqual(reader.entries.count, count)
        for (index, entry) in reader.entries.enumerated() {
            XCTAssertEqual(try reader.read(entry), Data([UInt8(truncatingIfNeeded: index + 1)]))
        }
        let stats = try XCTUnwrap(updater.lastCommitStatistics)
        XCTAssertEqual(stats.reencodedFolderCount, count)
        XCTAssertEqual(stats.reencodedPackBytes, stats.reencodeScratchWrittenBytes)
        let edited = try XCTUnwrap(SevenZipEditModel.read(reader))
        XCTAssertEqual(stats.reencodedPackBytes, edited.packs.reduce(0) { $0 + $1.length })
        // sequential で暗号化変換後に追加すると、変換済み pack も scratch を通る。
        // すべての range が共有ファイルの先頭を指す退行を、内容照合まで含めて検出する。
        let encryptedOutput = root.appendingPathComponent("encrypted.7z")
        let encrypted = try SevenZipUpdater.$testingDisablesClone.withValue(true) {
            try SevenZipUpdater.open(url: source, output: encryptedOutput,
                options: WriterOptions(lzmaLevel: 0, password: "secret", compressionThreads: 1))
        }
        let conversionCount = Mutex(0)
        try ScratchFile.$testingCreated.withValue({ _ in conversionCount.withLock { $0 += 1 } }) {
            try encrypted.reencryptExistingEntries(currentPassword: nil)
            try encrypted.add(data: Data([201]), as: "added")
            try encrypted.commit()
        }
        XCTAssertLessThanOrEqual(conversionCount.withLock { $0 }, 2)
        let decrypted = try SevenZipEditSupport.reader(encryptedOutput, password: "secret")
        XCTAssertEqual(decrypted.entries.count, count * 2 + 1)
        for (index, entry) in decrypted.entries.dropLast().enumerated() {
            let expected = index / 2 + index % 2
            XCTAssertEqual(try decrypted.read(entry), Data([UInt8(truncatingIfNeeded: expected)]))
        }
        XCTAssertEqual(try decrypted.read(decrypted.entries.last!), Data([201]))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
