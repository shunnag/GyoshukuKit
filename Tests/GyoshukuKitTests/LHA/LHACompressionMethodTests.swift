import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHACompressionMethodTests: XCTestCase {
    private let methods: [LHACompressionMethod] = [.lh5, .lh6, .lh7, .stored]
    private let levels = [1, WriterOptions().lhaLevel, 9]
    private var lhaUnix: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lha-unix").path }

    func testMethodsLevelsAndParallelHistoriesRoundTripWithIndependentTools() throws {
        let long = longDistanceInput()
        let line = Data("LHA static Huffman text 日本語\n".utf8)
        var text = Data()
        while text.count < 1 << 20 { text.append(line.prefix((1 << 20) - text.count)) }
        let items: [ExpectedEntry] = [
            .init(name: "empty"), .init(name: "one", data: Data([0x9F])),
            .init(name: "text.txt", data: text), .init(name: "random.bin", data: LHATestSupport.random(8 << 20)),
            .init(name: "distance.bin", data: long), .init(name: "folder/", kind: .directory, permissions: 0o755),
            .init(name: "日本語.txt", data: text.prefix(4096))
        ]
        var packed: [String: Int] = [:]
        for method in methods {
            for level in levels {
                let label = "lha-method-\(method)-\(level)"
                let root = try TestSupport.directory(label)
                var reference: Data?
                for threads in [1, 4] {
                    let work = try TestSupport.work(in: root)
                    let options = WriterOptions(lhaMethod: method, lhaLevel: level, compressionThreads: threads)
                    let url = try archive(in: work, items: items, options: options)
                    let bytes = try Data(contentsOf: url)
                    if let reference { XCTAssertEqual(bytes, reference, "\(label) threads=\(threads)") }
                    else { reference = bytes }
                    let members = try LHABytes(bytes).members
                    XCTAssertEqual(members[0].method, "-lh0-")
                    XCTAssertEqual(members[1].method, "-lh0-")
                    XCTAssertEqual(members[2].method, method.headerMethod)
                    XCTAssertEqual(members[3].method, "-lh0-")
                    XCTAssertEqual(members[3].payload, items[3].data)
                    XCTAssertEqual(members[5].method, "-lhd-")
                    XCTAssertEqual(members[6].extensions[1], Data([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x2E, 0x74, 0x78, 0x74]))
                    packed["\(method)-\(level)"] = members[4].payload.count
                    if method == .stored {
                        for (member, item) in zip(members, items) { XCTAssertEqual(member.payload, item.data) }
                    }
                    if method == .lh6 || method == .lh7 {
                        XCTAssertEqual(members[4].method, method.headerMethod)
                        let stream = try LH5Stream(members[4].payload, size: long.count, dictionaryBits: method.dictionaryBits)
                        XCTAssertTrue(stream.matches.contains { $0.distance > 8192 })
                        // 次の chunk の先頭で一致するには、前の chunk の末尾を window 一つ分運ぶ必要がある。
                        XCTAssertTrue(stream.matches.contains { ((1 << 20)..<((1 << 20) + 1024)).contains($0.offset) && $0.distance > 8192 })
                        if method == .lh7 {
                            XCTAssertTrue(stream.matches.contains { $0.distance > 32768 })
                            XCTAssertTrue(stream.matches.contains { ((2 << 20)..<((2 << 20) + 1024)).contains($0.offset) && $0.distance > 32768 })
                        }
                        XCTAssertEqual(stream.matches.map(\.length).max(), 256)
                    }
                    if threads == 1 { try TestSupport.assertKaitoKitRoundTrip(url, expected: items) }
                    // 逐次・並列の全 byte は一致済み。実ツールは並列側を照合する。
                    if threads == 4 {
                        // macOS の Lhasa / 7zz は CP932 名の抽出を復元できないため、ASCII member の全本文を抽出して照合する。
                        try LHATestSupport.verify(url, expected: items, externalNames: items.dropLast().map(\.name))
                        LHATestSupport.clean(try LHATestSupport.run(ReferenceTool.lhasa, ["t", url.path], in: work, log: "lha-t-all"))
                        LHATestSupport.clean(try LHATestSupport.run(ReferenceTool.sevenZip, ["t", url.path], in: work, log: "7zz-t-all"), sevenZip: true)
                        let unix = try ReferenceTool.run(lhaUnix, ["-t", "--archive-kanji-code=sjis", "--system-kanji-code=utf8", url.path],
                                                       in: work, log: "lha-unix-t", workingDirectory: work)
                        XCTAssertTrue(unix.text.contains("日本語.txt"), unix.text)
                        let listing = try LHATestSupport.run(ReferenceTool.sevenZip, ["l", "-slt", url.path], in: work, log: "7zz-methods")
                        let listed = SevenZipTestSupport.listingEntries(listing.text)
                        // 7zz 26.03 の LZH handler は LH5/LH6/LH7 を -lh5-/-lh6-/-lh7- と表示する。
                        XCTAssertEqual(listed[2]["Method"], method.headerMethod)
                    }
                    // 12 MiB の入力に対する書庫と抽出物を、成功時は残さない。診断 log は保持する。
                    if testRun?.failureCount == 0 {
                        if threads == 1 { try FileManager.default.removeItem(at: url) }
                        else {
                            for name in ["archive.lzh", "lha-extracted", "7zz-extracted"] {
                                try FileManager.default.removeItem(at: work.appendingPathComponent(name))
                            }
                        }
                    }
                }
            }
        }
        for level in levels {
            XCTAssertLessThan(try XCTUnwrap(packed["lh7-\(level)"]), try XCTUnwrap(packed["lh5-\(level)"]))
            TestSupport.report("LHA DISTANCE level=\(level): LH5=\(packed["lh5-\(level)"]!), LH6=\(packed["lh6-\(level)"]!), LH7=\(packed["lh7-\(level)"]!) bytes")
        }
    }

    func testFullDictionaryDistancesAndMaximumMatchAtEachLevel() throws {
        let root = try TestSupport.directory("lha-full-dictionaries")
        for method in methods where method != .stored {
            let seed = LHATestSupport.random(method.windowSize)
            let data = seed + seed.prefix(256) + Data([seed[256] ^ 0xFF])
            for level in levels {
                let work = try TestSupport.work(in: root)
                let encoded = try LH5Encoder.encode(data, configuration: .init(method: method, level: level))
                let stream = try LH5Stream(encoded, size: data.count, dictionaryBits: method.dictionaryBits)
                XCTAssertTrue(stream.matches.contains { $0.offset == seed.count && $0.distance == seed.count && $0.length == 256 })
                let url = try encodedArchive(in: work, data: data, encoded: encoded, method: method)
                try TestSupport.assertKaitoKitRoundTrip(url, expected: [.init(name: "data.bin", data: data)])
                for (index, tool) in [ReferenceTool.lhasa, lhaUnix, ReferenceTool.sevenZip].enumerated() {
                    try ReferenceTool.run(tool, ["t", url.path], in: work, log: "full-window-\(index)")
                }
            }
        }
    }

    func testEffortChangesChainSearchAndLazyMatchSelection() throws {
        let root = try TestSupport.directory("lha-effort-selection")
        let needle = Data("abc".utf8) + Data(repeating: 0x78, count: 120)
        var chain = needle
        for byte in UInt8(0x41)...UInt8(0x60) { chain.append(Data("abc".utf8) + Data([byte, 0x21])) }
        chain.append(contentsOf: 0..<8)
        let target = chain.count
        chain.append(needle)
        for level in [1, 6] {
            let encoded = try LH5Encoder.encode(chain, configuration: .init(level: level))
            let stream = try LH5Stream(encoded, size: chain.count)
            let match = try XCTUnwrap(stream.matches.first { $0.offset == target })
            if level == 1 { XCTAssertEqual(match.length, 3) }
            else { XCTAssertEqual(match.length, needle.count) }
            let url = try encodedArchive(in: TestSupport.work(in: root), data: chain, encoded: encoded, method: .lh5)
            try TestSupport.assertKaitoKitRoundTrip(url, expected: [.init(name: "data.bin", data: chain)])
        }
        let prefix = Data("xABQzABCDEFGHIJKz".utf8)
        let lazy = prefix + Data("xABCDEFGHIJK".utf8)
        for level in [6, 8, 9] {
            let encoded = try LH5Encoder.encode(lazy, configuration: .init(level: level))
            let stream = try LH5Stream(encoded, size: lazy.count)
            if level == 6 { XCTAssertTrue(stream.matches.contains { $0.offset == prefix.count && $0.length == 3 }) }
            else { XCTAssertTrue(stream.matches.contains { $0.offset == prefix.count + 1 && $0.length == 11 }) }
            let url = try encodedArchive(in: TestSupport.work(in: root), data: lazy, encoded: encoded, method: .lh5)
            try TestSupport.assertKaitoKitRoundTrip(url, expected: [.init(name: "data.bin", data: lazy)])
        }
    }

    func testForcedStoreNeverInvokesEncoder() throws {
        let root = try TestSupport.directory("lha-forced-store-no-codec")
        let output = root.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: output, format: .lha,
            options: .init(lhaMethod: .stored, compressionThreads: 4), lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize,
            lh5Encoder: { _ in throw WriterError.invalidState })
        let small = Data(repeating: 65, count: 8192), large = Data(repeating: 66, count: 3 << 20)
        try writer.add(data: small, as: "small", modificationDate: TestSupport.date)
        try writer.add(data: large, as: "large", modificationDate: TestSupport.date)
        try writer.finish()
        XCTAssertEqual(try LHABytes(Data(contentsOf: output)).members.map(\.method), ["-lh0-", "-lh0-"])
        try TestSupport.assertKaitoKitRoundTrip(output, expected: [.init(name: "small", data: small), .init(name: "large", data: large)])
    }

    func testEmptyArchivesAtAllMethodsAndLevels() throws {
        let root = try TestSupport.directory("lha-method-empty")
        let baseline = root.appendingPathComponent("baseline.lzh")
        try Data([0]).write(to: baseline)
        // 7zz は空 LHA を書庫と認識しない。各ツールの空書庫の既知の挙動と同じことを確認する。
        let tools = [ReferenceTool.lhasa, lhaUnix, ReferenceTool.sevenZip]
        let statuses = try tools.enumerated().map { index, tool in
            try ReferenceTool.run(tool, ["t", baseline.path], in: root, log: "baseline-\(index)", expect: .unchecked).status
        }
        for method in methods {
            for level in levels {
                for threads in [1, 4] {
                    let work = try TestSupport.work(in: root)
                    let url = try archive(in: work, items: [], options: .init(lhaMethod: method, lhaLevel: level, compressionThreads: threads))
                    XCTAssertEqual(try Data(contentsOf: url), Data([0]))
                    try TestSupport.assertKaitoKitRoundTrip(url, expected: [])
                    for (index, tool) in tools.enumerated() {
                        XCTAssertEqual(try ReferenceTool.run(tool, ["t", url.path], in: work, log: "empty-\(index)", expect: .unchecked).status, statuses[index])
                    }
                }
            }
        }
    }

    func testLHaForUNIXProducesLH6AndLH7ReadableByKaitoKit() throws {
        let root = try TestSupport.directory("lha-unix-reverse-methods")
        let usage = try ReferenceTool.run(lhaUnix, ["--help"], in: root, log: "usage")
        XCTAssertTrue(usage.text.contains("o[567]"), usage.text)
        let input = root.appendingPathComponent("distance.bin")
        let data = longDistanceInput()
        try data.write(to: input)
        for method in [6, 7] {
            let url = root.appendingPathComponent("unix-\(method).lzh")
            try ReferenceTool.run(lhaUnix, ["-ao\(method)2", url.path, input.lastPathComponent], in: root, log: "create-\(method)", workingDirectory: root)
            XCTAssertEqual(try LHABytes(Data(contentsOf: url)).members.first?.method, "-lh\(method)-")
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.entries.map(\.name), [input.lastPathComponent])
            XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), data)
            try ReferenceTool.run(lhaUnix, ["-t", url.path], in: root, log: "test-\(method)")
        }
    }

    func testUpdaterCarriesExistingBytesAndRewriterUsesSelectedMethodAndLevel() throws {
        let root = try TestSupport.directory("lha-edit-methods")
        let data = longDistanceInput()
        // 長距離入力だけでは全levelのtokenが同じになる。小さい追加にも探索量とlazy matchingの差を含める。
        let needle = Data("abc".utf8) + Data(repeating: 0x78, count: 120)
        var effort = needle
        for byte in UInt8(0x41)...UInt8(0x60) { effort.append(Data("abc".utf8) + Data([byte, 0x21])) }
        effort.append(contentsOf: 0..<8)
        effort.append(needle)
        effort.append(contentsOf: 8..<16)
        effort.append(Data("xABQzABCDEFGHIJKzxABCDEFGHIJK".utf8))
        let source = try archive(in: root, items: [.init(name: "old", data: Data(repeating: 65, count: 8192))], options: .init(compressionThreads: 1))
        let carried = try XCTUnwrap(LHABytes(Data(contentsOf: source)).members.first)
        for method in methods {
            for level in levels {
                let options = WriterOptions(lhaMethod: method, lhaLevel: level, compressionThreads: 4)
                let added: [ExpectedEntry] = [.init(name: "new", data: data), .init(name: "effort", data: effort)]
                let expected = try archive(in: TestSupport.work(in: root), items: added, options: options)
                let encoded = try LHABytes(Data(contentsOf: expected)).members
                let work = try TestSupport.work(in: root)
                let updated = work.appendingPathComponent("updated.lzh")
                let updater = try LHAUpdater.open(url: source, output: updated, options: options)
                try updater.add(data: data, as: "new", modificationDate: TestSupport.date)
                try updater.add(data: effort, as: "effort", modificationDate: TestSupport.date)
                try updater.commit()
                let members = try LHABytes(Data(contentsOf: updated)).members
                XCTAssertEqual(members[0].header + members[0].payload, carried.header + carried.payload)
                for (member, expected) in zip(members.dropFirst(), encoded) {
                    XCTAssertEqual(member.header + member.payload, expected.header + expected.payload)
                }
                try TestSupport.assertKaitoKitRoundTrip(updated, expected: [.init(name: "old", data: Data(repeating: 65, count: 8192))] + added)
                let rewritten = work.appendingPathComponent("rewritten.lzh")
                let rewriter = try ArchiveRewriter.open(url: expected, output: rewritten, format: .lha, options: options)
                try rewriter.add(data: data, as: "addition", modificationDate: TestSupport.date)
                try rewriter.add(data: effort, as: "effort-addition", modificationDate: TestSupport.date)
                try rewriter.commit()
                let newMembers = try LHABytes(Data(contentsOf: rewritten)).members
                XCTAssertEqual(newMembers.count, 4)
                for (member, expected) in zip(newMembers, encoded + encoded) {
                    XCTAssertEqual(member.method, expected.method)
                    XCTAssertEqual(member.payload, expected.payload)
                }
                try TestSupport.assertKaitoKitRoundTrip(rewritten, expected: added + [.init(name: "addition", data: data), .init(name: "effort-addition", data: effort)])
            }
        }
    }

    func testOptionValidationAndPendingInputBounds() throws {
        XCTAssertEqual(WriterOptions().lhaMethod, .lh5)
        XCTAssertEqual(WriterOptions().lhaLevel, 6)
        let root = try TestSupport.directory("lha-method-options")
        let source = try archive(in: root, items: [], options: .init())
        for level in [Int.min, 0, 10, Int.max] {
            let options = WriterOptions(lhaMethod: .stored, lhaLevel: level)
            let output = root.appendingPathComponent("invalid-\(level).lzh")
            for operation in [
                { _ = try ArchiveWriter.create(url: output, format: .lha, options: options) },
                { _ = try LHAUpdater.open(url: source, output: output, options: options) },
                { _ = try ArchiveRewriter.open(url: source, output: output, format: .lha, options: options) }
            ] {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WriterError, .invalidOption("lhaLevel")) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
        for method in methods {
            for threads in [1, 4, 64] {
                let options = WriterOptions(lhaMethod: method, compressionThreads: threads)
                let pieces = UInt64(threads * ((1 << 20) + method.windowSize))
                let entries = EntryCompressionConfiguration(lhaThreads: threads).maximumPendingInputBytes
                let expected = threads == 1 || method == .stored ? 0 : max(pieces, entries)
                XCTAssertEqual(options.maximumPendingInputBytes(for: .lha), expected)
            }
        }
    }

    private func longDistanceInput() -> Data {
        let seed = LHATestSupport.random(64 << 10)
        var input = Data()
        while input.count < 1536 << 10 { input.append(seed.prefix(16 << 10)) }
        while input.count < 3 << 20 { input.append(seed.suffix(48 << 10).prefix((3 << 20) - input.count)) }
        return input
    }

    private func archive(in directory: URL, items: [ExpectedEntry], options: WriterOptions) throws -> URL {
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha, options: options)
        for item in items {
            if item.kind == .directory {
                try writer.addDirectory(String(item.name.dropLast()), modificationDate: item.date, ownerIDs: nil)
            } else {
                try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.permissions)
            }
        }
        try writer.finish()
        XCTAssertEqual(writer.pendingInputBytes, 0)
        return url
    }

    private func encodedArchive(in directory: URL, data: Data, encoded: Data, method: LHACompressionMethod) throws -> URL {
        let url = directory.appendingPathComponent("archive.lzh")
        let entry = try LHARecords.Entry(name: "data.bin", mode: 0o100644, size: UInt64(data.count), date: TestSupport.date)
        try (entry.header(method: method.headerMethod, packedSize: UInt32(encoded.count), crc: LHATestSupport.crc(data)) + encoded + Data([0])).write(to: url)
        return url
    }
}
