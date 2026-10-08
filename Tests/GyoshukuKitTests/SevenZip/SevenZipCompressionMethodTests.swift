import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipCompressionMethodTests: XCTestCase {
    func testWriterMethodsAndEncryptionRoundTrip() throws {
        let root = try TestSupport.directory("7z-methods-writer")
        let items = SevenZipMethodTestSupport.corpus()
        for method in SevenZipMethodTestSupport.methods {
            for mode in 0..<3 {
                let work = try TestSupport.work(in: root)
                let options = SevenZipMethodTestSupport.options(method, mode: mode)
                for empty in [true, false] {
                    let url = work.appendingPathComponent(empty ? "empty.7z" : "corpus.7z")
                    let expected = empty ? [] : items
                    try SevenZipMethodTestSupport.write(url, items: expected, options: options)
                    let model = try SevenZipMethodTestSupport.verify(url, items: expected, password: options.password, method: method)
                    XCTAssertEqual(model.header.encrypted, mode == 2)
                    XCTAssertEqual(model.folders.count, expected.filter { !$0.data.isEmpty }.count)
                    if method.value == .copy && mode == 0 {
                        let bytes = try Data(contentsOf: url)
                        for (pack, item) in zip(model.packs, expected.filter { !$0.data.isEmpty }) {
                            XCTAssertEqual(bytes.subdata(in: Int(pack.range.lowerBound)..<Int(pack.range.upperBound)), item.data)
                        }
                    }
                }
            }
        }
        // 8 MiB の乱数と展開先を含む行列は数十 MiB を超えるので、成功した検証の出力を片付ける。
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testReferenceArchivesAreReadByteIdentically() throws {
        let root = try TestSupport.directory("7z-methods-reverse")
        let items = SevenZipMethodTestSupport.corpus()
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for item in items {
            let path = input.appendingPathComponent(item.name)
            if item.kind == .directory { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            else { try item.data.write(to: path) }
        }
        for method in SevenZipMethodTestSupport.additionalMethods {
            for mode in 0..<3 {
                let work = try TestSupport.work(in: root), url = work.appendingPathComponent("reference.7z")
                let options = SevenZipMethodTestSupport.options(method, mode: mode)
                let encryption = mode == 0 ? [] : ["-psecret", "-mhe=\(mode == 2 ? "on" : "off")"]
                try ReferenceTool.run(ReferenceTool.sevenZip,
                    ["a", "-t7z", "-m0=" + method.name, "-ms=off", "-mhc=off"] + encryption + [url.path] + items.map(\.name),
                    in: work, log: "7zz-a-\(method.name)-\(mode)", workingDirectory: input)
                try SevenZipMethodTestSupport.verify(url, items: items, password: options.password,
                                                     method: method, ordered: false, metadata: false)
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testLevelsThreadsShortReadsAndDrainKeepOneStream() throws {
        let root = try TestSupport.directory("7z-methods-levels")
        let payload = TestCorpus.pseudoSource(mebibytes: 2) + TestCorpus.random(137)
        let items: [ExpectedEntry] = [.init(name: "payload", data: payload), .init(name: "empty"), .init(name: "tail", data: Data([3]))]
        for method in SevenZipMethodTestSupport.additionalMethods {
            let levels = method.value == .deflate ? [0, 9] : method.value == .bzip2 ? [1, 9] : [6]
            for level in levels {
                var baseline: Data?
                for (threads, shortReads, drain) in [(1, false, false), (4, true, true)] {
                    let work = try TestSupport.work(in: root), url = work.appendingPathComponent("output.7z")
                    let options = WriterOptions(sevenZipMethod: method.value, deflateLevel: level,
                        bzip2Level: method.value == .bzip2 ? level : 9, compressionThreads: threads)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: url)
                    let writer = try SevenZipWriter(output: handle, url: url, options: options)
                    for item in items {
                        if shortReads {
                            var position = 0
                            try writer.add(name: item.name, mode: 0o100644, size: UInt64(item.data.count), date: TestSupport.date) { requested in
                                let count = min(requested, 7919, item.data.count - position)
                                defer { position += count }
                                return item.data.subdata(in: position..<position + count)
                            }
                        } else {
                            // 一括 disk 追加の先読み経路。方式ごとの上限を超える入力の分割も確かめる。
                            try writer.add(name: item.name, mode: 0o100644, date: TestSupport.date,
                                           prefetched: .init(data: item.data, crc: CRC32.checksum(item.data)))
                        }
                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: .sevenZip))
                    }
                    if drain {
                        let pending = writer.pendingInputBytes
                        var emitted: UInt64 = 0
                        try writer.finishAdditions { emitted += $0 }
                        XCTAssertEqual(emitted, pending)
                        XCTAssertEqual(writer.pendingInputBytes, 0)
                    }
                    try writer.finish()
                    let bytes = try Data(contentsOf: url)
                    if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
                    let model = try SevenZipMethodTestSupport.verify(url, items: items, password: nil, method: method)
                    if method.value == .bzip2 {
                        // 単一 stream の system encoder と照合し、block ごとの stream 連結を検出する。
                        let range = try XCTUnwrap(model.packs.first).range
                        XCTAssertEqual(bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)),
                                       try Bzip2StreamEncoder.encode(payload, level: level))
                    }
                }
            }
        }
        if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
    }

    func testOptionsValidateBeforeCreatingOutputAndReportPendingBounds() throws {
        let root = try TestSupport.directory("7z-methods-options")
        XCTAssertEqual(WriterOptions().sevenZipMethod, .lzma2)
        // 最大block指定も入力上界を飽和させ、追加bufferの和であふれない。
        let largestBlock = WriterOptions(sevenZipMethod: .bzip2, sevenZipSolid: .on(blockSize: .max), compressionThreads: 1)
        XCTAssertEqual(largestBlock.maximumPendingInputBytes(for: .sevenZip), .max)
        for method in SevenZipMethodTestSupport.methods {
            for threads in [1, 4, 64] {
                let options = SevenZipMethodTestSupport.options(method, mode: 0, threads: threads)
                let expected: UInt64
                switch method.value {
                case .lzma2: expected = threads == 1 ? 16 << 20 : threads == 4 ? 64 << 20 : 1024 << 20
                case .deflate: expected = threads == 1 ? 1 << 20 : threads == 4 ? 4 << 20 : 64 << 20
                case .copy: expected = 0
                case .bzip2:
                    let entryWindow: UInt64 = threads == 1 ? 0 : threads == 4 ? 80 << 20 : 272 << 20
                    // 物理メモリ8 GiBではinner=threads。並列spliceは(inner + 1) × 8 MiBを保持する。
                    let inner = threads
                    let spliceBuffers: UInt64 = UInt64(inner + 1) * (8 << 20)
                    expected = max(entryWindow, spliceBuffers)
                default: expected = threads == 1 ? 0 : threads == 4 ? 80 << 20 : 272 << 20
                }
                EntryCompressionConfiguration.$testingEntryThreadLimit.withValue(16) {
                    XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 8 << 30), expected)
                }
                XCTAssertNoThrow(try options.validate(for: .sevenZip))
            }
            for (deflate, bzip2, field) in [(-1, 9, "deflateLevel"), (10, 9, "deflateLevel"), (6, 0, "bzip2Level"), (6, 10, "bzip2Level")] {
                let url = root.appendingPathComponent("invalid-\(method.name)-\(deflate)-\(bzip2).7z")
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: .sevenZip,
                    options: WriterOptions(sevenZipMethod: method.value, deflateLevel: deflate, bzip2Level: bzip2))) {
                    XCTAssertEqual($0 as? WriterError, .invalidOption(field))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
