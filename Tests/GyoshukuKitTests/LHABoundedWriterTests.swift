import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHABoundedWriterTests: XCTestCase {
    func testChunkBoundariesAndStoredFallbackPreserveFollowingMembers() throws {
        let directory = try ZipTestSupport.directory("lha-bounded-members")
        let url = directory.appendingPathComponent("archive.lzh")
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        let items: [LHATestSupport.Expected] = [
            .init(name: "before.txt", data: Data("before".utf8)),
            .init(name: "below.bin", data: Data(repeating: 65, count: 1_048_575)),
            .init(name: "exact.bin", data: Data(repeating: 66, count: 1_048_576)),
            .init(name: "above.bin", data: Data(repeating: 67, count: 1_048_577)),
            .init(name: "random.bin", data: LHATestSupport.random(2_097_169)),
            .init(name: "compressed.bin", data: LHATestSupport.random(2_097_181, alphabetMask: 63)),
            .init(name: "after.txt", data: Data("after".utf8))
        ]
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: ZipTestSupport.date) }
        try writer.finish()
        let members = try LHABytes(Data(contentsOf: url)).members
        XCTAssertEqual(members.map(\.method), ["-lh0-", "-lh5-", "-lh5-", "-lh5-", "-lh0-", "-lh5-", "-lh0-"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".gyoshuku-") })
        try LHATestSupport.verify(url, expected: items)
    }

    func testShortReadsStillProduceOneContinuousBitstream() throws {
        let directory = try ZipTestSupport.directory("lha-short-reads")
        let data = LHATestSupport.random(2_097_171, alphabetMask: 31)
        let source = directory.appendingPathComponent("source.bin"), url = directory.appendingPathComponent("archive.lzh")
        try data.write(to: source)
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        var reads = 0
        try writer.add(contentsOf: source, as: "short.bin") { file, count in
            reads += 1
            return try file.read(upToCount: min(count, 997)) ?? Data()
        }
        try writer.finish()
        XCTAssertGreaterThan(reads, 2_000)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(try reader.read(reader.entries[0]), data)
        LHATestSupport.clean(try LHATestSupport.run(LHATestSupport.lhasa, ["t", url.path], in: directory, log: "short-lha"))
        LHATestSupport.clean(try LHATestSupport.run(LHATestSupport.sevenZip, ["t", url.path], in: directory, log: "short-7zz"), sevenZip: true)
    }

    func testMidstreamSourceFailuresEraseOutputAndHardlinkWithoutSpoolLeaks() throws {
        for earlyEOF in [false, true] {
            let directory = try ZipTestSupport.directory("lha-stream-failure-\(earlyEOF)")
            let data = Data(repeating: 81, count: 3_145_751)
            let source = directory.appendingPathComponent("source.bin"), url = directory.appendingPathComponent("archive.lzh")
            let alias = directory.appendingPathComponent("alias.lzh")
            try data.write(to: source)
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            try FileManager.default.linkItem(at: url, to: alias)
            var bytes = 0
            XCTAssertThrowsError(try writer.add(contentsOf: source, as: "payload.bin") { file, count in
                if bytes > 1_048_576 {
                    if earlyEOF { return Data() }
                    throw CocoaError(.fileReadUnknown)
                }
                let result = try file.read(upToCount: count) ?? Data()
                bytes += result.count
                return result
            })
            XCTAssertGreaterThan(bytes, 1_048_576)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: alias).count, 0)
            XCTAssertEqual(try Data(contentsOf: source), data)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".gyoshuku-") })
            XCTAssertThrowsError(try writer.finish())
        }
    }

    func testCancellationAfterFirstSpoolChunkRemovesPartialArchive() async throws {
        let directory = try ZipTestSupport.directory("lha-stream-cancel")
        let source = directory.appendingPathComponent("source.bin"), url = directory.appendingPathComponent("archive.lzh")
        try Data(repeating: 67, count: 3_145_751).write(to: source)
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: url, format: .lha)
            var bytes = 0
            try writer.add(contentsOf: source, as: "payload.bin") { file, count in
                let result = try file.read(upToCount: count) ?? Data()
                bytes += result.count
                if bytes > 1_048_576 { withUnsafeCurrentTask { $0?.cancel() } }
                return result
            }
            try writer.finish()
        }
        do { try await task.value; XCTFail("cancelled writer succeeded") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.bin"])
    }
}
