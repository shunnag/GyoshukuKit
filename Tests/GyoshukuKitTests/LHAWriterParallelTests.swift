import Darwin
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAWriterParallelTests: XCTestCase {
    func testThreeHundredMembersMatchIndependentSerialReferenceAtEveryThreadCount() throws {
        let directory = try ZipTestSupport.directory("lha-parallel-300")
        let below = Data(repeating: 65, count: 1_048_575)
        let exact = Data(repeating: 66, count: 1_048_576)
        let random = LHATestSupport.random(1_048_576)
        let items: [(name: String, data: Data, directory: Bool)] = (0..<300).map { index in
            let kind = index % 100
            let data: Data
            switch kind {
            case 0, 5: data = Data()
            case 1: data = Data([67])
            case 3: data = below
            case 4: data = exact
            case 6: data = random
            default: data = Data(repeating: UInt8(index % 251), count: 1024)
            }
            return ("member-\(index)" + (kind == 5 ? "/" : ".bin"), data, kind == 5)
        }
        var reference = Data()
        var memberEnds: [UInt64] = []
        for item in items {
            reference.append(try LHAWriterParallelTests.serialMember(item.data, name: item.name, directory: item.directory))
            memberEnds.append(UInt64(reference.count))
        }
        reference.append(0)
        for threads in [1, 2, 4, 8, 16] {
            let url = directory.appendingPathComponent("threads-\(threads).lzh")
            let writer = try ArchiveWriter.create(url: url, format: .lha,
                                                  options: WriterOptions(compressionThreads: threads))
            let observer = try writer.duplicateOutput()
            defer { try? observer.close() }
            for (index, item) in items.enumerated() {
                if item.directory {
                    try writer.addDirectory(item.name, modificationDate: ZipTestSupport.date, ownerIDs: nil)
                } else {
                    try writer.add(data: item.data, as: item.name, modificationDate: ZipTestSupport.date)
                }
                if threads == 1 {
                    XCTAssertEqual(try observer.offset(), memberEnds[index], item.name)
                }
            }
            try writer.finish()
            let actual = try Data(contentsOf: url)
            XCTAssertTrue(actual == reference, "threads=\(threads)")
            let members = try LHABytes(actual).members
            XCTAssertEqual(members.count, 300)
            XCTAssertEqual(members[6].method, "-lh0-")
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.entries.count, items.count)
            for (entry, item) in zip(reader.entries, items) where !item.directory {
                XCTAssertEqual(try reader.read(entry), item.data, "threads=\(threads), \(item.name)")
            }
        }
    }

    func testEncoderFailureIsDeferredToAddFinishLargeDrainAndEndMembers() throws {
        for stage in ["add", "finish", "large", "endMembers"] {
            let directory = try ZipTestSupport.directory("lha-parallel-fail-\(stage)")
            let url = directory.appendingPathComponent("archive.lzh")
            let alias = directory.appendingPathComponent("alias.lzh")
            let writer = try LHAWriterParallelTests.create(url, threads: 2) { _ in throw WriterError.compression(-77) }
            try FileManager.default.linkItem(at: url, to: alias)
            try writer.add(data: Data([1]), as: "first")
            try writer.addDirectory("directory", modificationDate: ZipTestSupport.date, ownerIDs: nil)
            XCTAssertThrowsError(try {
                switch stage {
                case "add": try writer.add(data: Data([2]), as: "next")
                case "large": try writer.add(data: Data(repeating: 65, count: 1_048_577), as: "large")
                case "endMembers": _ = try writer.endLHAMembers()
                default: try writer.finish()
                }
            }()) { XCTAssertEqual($0 as? WriterError, .compression(-77)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), stage)
            XCTAssertEqual(try Data(contentsOf: alias).count, 0, stage)
            XCTAssertThrowsError(try writer.finish())
        }
    }

    func testDirectoriesDoNotRunEncoderAndWorkerCancellationRemovesOutput() throws {
        let directory = try ZipTestSupport.directory("lha-parallel-directory")
        let url = directory.appendingPathComponent("directory.lzh")
        let writer = try LHAWriterParallelTests.create(url, threads: 2) { _ in throw CancellationError() }
        try writer.addDirectory("表", modificationDate: ZipTestSupport.date, ownerIDs: nil)
        try writer.finish()
        XCTAssertEqual(try LHABytes(Data(contentsOf: url)).members.map(\.method), ["-lhd-"])
        let failing = directory.appendingPathComponent("cancelled.lzh")
        let cancelled = try LHAWriterParallelTests.create(failing, threads: 2) { _ in throw CancellationError() }
        try cancelled.add(data: Data([0]), as: "file")
        XCTAssertThrowsError(try cancelled.finish()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failing.path))
    }

    func testCapacityWaitPrecedesInputReadAndCancellationAbandonsPendingMembers() async throws {
        let directory = try ZipTestSupport.directory("lha-parallel-capacity-cancel")
        let source = directory.appendingPathComponent("source")
        let url = directory.appendingPathComponent("archive.lzh")
        let alias = directory.appendingPathComponent("alias.lzh")
        try Data([3]).write(to: source)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let submitting = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let writer = try LHAWriterParallelTests.create(url, threads: 2) { input in
                started.signal()
                release.wait()
                return input
            }
            try FileManager.default.linkItem(at: url, to: alias)
            try writer.add(data: Data([1]), as: "first")
            try writer.add(data: Data([2]), as: "second")
            submitting.signal()
            try writer.add(contentsOf: source, as: "third") { file, count in
                read.signal()
                return try file.read(upToCount: count) ?? Data()
            }
            try writer.finish()
        }
        defer { release.signal(); release.signal(); task.cancel() }
        for _ in 0..<2 { try await LZMA2ChunkPipelineTests.wait(started) }
        try await LZMA2ChunkPipelineTests.wait(submitting)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(read.wait(timeout: .now()), .timedOut)
        task.cancel()
        do { try await task.value; XCTFail("cancelled writer succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(read.wait(timeout: .now()), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data([3]))
    }

    func testInputIsConsumedBeforeDeferredAddReturns() async throws {
        let directory = try ZipTestSupport.directory("lha-parallel-consumed")
        let source = directory.appendingPathComponent("source")
        let url = directory.appendingPathComponent("archive.lzh")
        let input = Data(repeating: 84, count: 1024)
        try input.write(to: source)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writer = try LHAWriterParallelTests.create(url, threads: 2) { data in
            started.signal()
            release.wait()
            return try LH5Encoder.encode(data)
        }
        defer { release.signal() }
        var consumed = 0, sawEOF = false
        try writer.add(contentsOf: source, as: "source") { file, count in
            let data = try file.read(upToCount: count) ?? Data()
            consumed += data.count
            if data.isEmpty { sawEOF = true }
            return data
        }
        XCTAssertEqual(consumed, input.count)
        XCTAssertTrue(sawEOF)
        try await LZMA2ChunkPipelineTests.wait(started)
        try FileManager.default.removeItem(at: source)
        release.signal()
        try writer.finish()
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(try reader.read(reader.entries[0]), input)
    }

    func testEndMembersRecordsAbsoluteOffsetsWithoutTerminatorOrClose() throws {
        let directory = try ZipTestSupport.directory("lha-parallel-records")
        for threads in [1, 4] {
            let url = directory.appendingPathComponent("records-\(threads).lzh")
            let prefix = Data(repeating: 0x42, count: 73)
            try prefix.write(to: url)
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try output.seekToEnd()
            var info = stat()
            XCTAssertEqual(fstat(output.fileDescriptor, &info), 0)
            let lha = LHAWriter(output: output, url: url, identity: (info.st_dev, info.st_ino), threads: threads)
            lha.recordsMembers = true
            let writer = ArchiveWriter(output: output, url: url, identity: (info.st_dev, info.st_ino), format: .lha,
                                       options: WriterOptions(compressionThreads: threads), lhaWriter: lha)
            try writer.addDirectory("表", modificationDate: ZipTestSupport.date, ownerIDs: nil)
            try writer.add(data: Data(repeating: 65, count: 1024), as: "表/ソ.bin", modificationDate: ZipTestSupport.date)
            try writer.add(data: Data(repeating: 66, count: 1_048_577), as: "large", modificationDate: ZipTestSupport.date)
            try writer.add(data: Data([67]), as: "after", modificationDate: ZipTestSupport.date)
            let end = try writer.endLHAMembers()
            XCTAssertEqual(try Data(contentsOf: url).count, Int(end))
            XCTAssertEqual(try output.offset(), end)
            try writer.finish()
            XCTAssertEqual(try output.offset(), end)
            XCTAssertThrowsError(try writer.add(data: Data(), as: "too-late"))
            try output.write(contentsOf: Data([0]))
            let bytes = try Data(contentsOf: url)
            let members = try LHABytes(Data(bytes.dropFirst(prefix.count))).members
            XCTAssertEqual(lha.memberRecords.count, 4)
            for (record, member) in zip(lha.memberRecords, members) {
                XCTAssertEqual(record.headerOffset, UInt64(prefix.count + member.offset))
                XCTAssertEqual(record.headerLength, UInt64(member.header.count))
                XCTAssertEqual(record.dataLength, UInt64(member.payload.count))
                XCTAssertEqual(record.method, member.method)
                let rawName = Data((member.extensions[2] ?? Data()).map { $0 == 0xFF ? 0x2F : $0 })
                    + (member.extensions[1] ?? Data())
                XCTAssertEqual(record.rawName, rawName)
            }
            XCTAssertTrue(lha.memberRecords[1].rawName.contains(0x5C))
            XCTAssertFalse(lha.memberRecords[1].rawName.contains(0xFF))
            lha.abort()
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    private static func create(_ url: URL, threads: Int,
                               encoder: @escaping @Sendable (Data) throws -> Data) throws -> ArchiveWriter {
        try ArchiveWriter.create(url: url, format: .lha, options: WriterOptions(compressionThreads: threads),
                                 lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize, lh5Encoder: encoder)
    }

    static func serialMember(_ input: Data, name: String, directory: Bool = false) throws -> Data {
        let entry = try LHARecords.Entry(name: name, mode: directory ? 0o40755 : 0o100644,
                                         size: UInt64(input.count), date: ZipTestSupport.date)
        let compressed = try LH5Encoder.encode(input)
        let shrinks = compressed.count < input.count
        let payload = shrinks ? compressed : input
        return try entry.header(method: directory ? "-lhd-" : shrinks ? "-lh5-" : "-lh0-",
                                packedSize: UInt32(payload.count), crc: LHACRC16.update(0, input)) + payload
    }
}
