import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ParallelLZMA2WriterTests: XCTestCase {
    private static let chunkSize = 1024 * 1024
    private static var payload: Data {
        Data(String(repeating: "parallel LZMA2 chunk boundaries\n", count: 130_000).utf8).prefix(7 * chunkSize / 2)
    }

    func testSevenZipMultiChunkBytesMatchSerialEncodingForEveryThreadCount() throws {
        let directory = try ZipTestSupport.directory("parallel-7z-chunks")
        let items = [SevenZipTestSupport.Expected(name: "large.txt", data: Self.payload)]
        let expected = try serialArchive(items)
        for threads in [1, 4, 8] {
            let url = directory.appendingPathComponent("threads-\(threads).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                                                 options: WriterOptions(compressionThreads: threads), lzmaChunkSize: Self.chunkSize)
            try writer.add(data: items[0].data, as: items[0].name, modificationDate: ZipTestSupport.date)
            try writer.finish()
            XCTAssertEqual(try Data(contentsOf: url), expected)
            try verify(url, items: items)
        }
    }

    func testSevenZipConsecutiveDiskEntriesAndEmptyMarkersAreByteIdentical() throws {
        let directory = try ZipTestSupport.directory("parallel-7z-files")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var items: [SevenZipTestSupport.Expected] = []
        for index in 0..<200 {
            if index == 51 { items.append(.init(name: "empty")) }
            if index == 103 { items.append(.init(name: "directory/", kind: .directory, mode: 0o755)) }
            items.append(.init(name: "file-\(index)", data: Data(String(repeating: "small file \(index)\n", count: 25).utf8)))
        }
        for item in items {
            let url = source.appendingPathComponent(item.name)
            if item.kind == .directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            else { try item.data.write(to: url) }
            try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date, .posixPermissions: item.mode],
                                                  ofItemAtPath: url.path)
        }
        let expected = try serialArchive(items)
        for threads in [1, 4, 8] {
            let url = directory.appendingPathComponent("threads-\(threads).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: WriterOptions(compressionThreads: threads))
            for item in items { try writer.add(contentsOf: source.appendingPathComponent(item.name), as: item.name) }
            try writer.finish()
            XCTAssertEqual(try Data(contentsOf: url), expected)
            try verify(url, items: items)
        }
    }

    func testSeparateAddsActuallyEncodeConcurrently() async throws {
        let directory = try ZipTestSupport.directory("parallel-7z-concurrent-adds")
        let source = directory.appendingPathComponent("source")
        let data = Data("consecutive disk entries".utf8)
        try data.write(to: source)
        let url = directory.appendingPathComponent("archive.7z")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: WriterOptions(compressionThreads: 4),
                                                 lzmaChunkSize: Self.chunkSize) { input in
                started.signal()
                release.wait()
                return try LZMA2Compressor.encode(input)
            }
            for index in 0..<4 { try writer.add(contentsOf: source, as: "file-\(index)") }
            try writer.finish()
        }
        defer { for _ in 0..<4 { release.signal() } }
        for _ in 0..<4 { try await LZMA2ChunkPipelineTests.wait(started) }
        for _ in 0..<4 { release.signal() }
        try await task.value
        try verify(url, items: (0..<4).map { .init(name: "file-\($0)", data: data) })
    }

    func testSevenZipAESMultiChunkAndConsecutiveEntriesWithEightThreads() throws {
        let directory = try ZipTestSupport.directory("parallel-7z-aes")
        let items: [SevenZipTestSupport.Expected] = [
            .init(name: "large", data: Self.payload), .init(name: "empty"),
            .init(name: "random", data: LHATestSupport.random(600_123)),
            .init(name: "last", data: Data("last encrypted entry".utf8))
        ]
        for encryptHeader in [false, true] {
            let url = directory.appendingPathComponent("header-\(encryptHeader).7z")
            let options = WriterOptions(password: EncryptionTestSupport.password, encryptsSevenZipHeaders: encryptHeader,
                                        compressionThreads: 8)
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: options, lzmaChunkSize: Self.chunkSize)
            for item in items { try writer.add(data: item.data, as: item.name, modificationDate: ZipTestSupport.date) }
            try writer.finish()
            try verify(url, items: items, password: EncryptionTestSupport.password)
        }
    }

    func testTarXZMultipleBlocksRoundTripAndDeterministicOutput() throws {
        let directory = try ZipTestSupport.directory("parallel-xz-roundtrip")
        var expected: Data?
        for threads in [1, 4, 8] {
            let url = try tarXZ(in: directory, threads: threads)
            let bytes = try Data(contentsOf: url)
            if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
            try verify(url, items: Self.tarItems)
        }
    }

    func testTarXZBlockCountAndChecksWithXZ() throws {
        let xz = try XCTUnwrap(try tool(["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]))
        let directory = try ZipTestSupport.directory("parallel-xz-xz-tool")
        let url = try tarXZ(in: directory)
        try ZipTestSupport.run(xz, ["-t", url.path], in: directory, log: "xz-test")
        let listing = try ZipTestSupport.run(xz, ["-l", "--robot", url.path], in: directory, log: "xz-list")
        let fields = try XCTUnwrap(listing.split(separator: "\n").first { $0.hasPrefix("file\t") }).split(separator: "\t")
        XCTAssertEqual(fields[1], "1")
        XCTAssertEqual(fields[2], Substring(String(try TarChunkLayoutTestSupport.expectedLengths(url, format: .tarXZ, limit: Self.chunkSize).count)))
        XCTAssertEqual(fields[6], "CRC32")
    }

    func testTarXZMembersWithBSDTar() throws {
        let tar = try XCTUnwrap(try tool(["/usr/bin/tar", "/opt/homebrew/bin/bsdtar"]))
        let directory = try ZipTestSupport.directory("parallel-xz-bsdtar")
        let url = try tarXZ(in: directory)
        let listing = try ZipTestSupport.run(tar, ["-tf", url.path], in: directory, log: "bsdtar-list")
        XCTAssertEqual(listing.split(separator: "\n").map(String.init), Self.tarItems.map(\.name))
    }

    func testTarXZChecksWithSevenZip() throws {
        let seven = try XCTUnwrap(try tool([SevenZipTestSupport.tool, "/usr/local/bin/7zz"]))
        let directory = try ZipTestSupport.directory("parallel-xz-7zz")
        let url = try tarXZ(in: directory)
        let output = try ZipTestSupport.run(seven, ["t", url.path], in: directory, log: "7zz-test")
        XCTAssertTrue(output.contains("Everything is Ok"))
    }

    func testXZWithoutInputHasZeroRecords() throws {
        let directory = try ZipTestSupport.directory("parallel-xz-zero-records")
        let url = directory.appendingPathComponent("empty.xz")
        let compressor = try ParallelXZCompressor(threads: 4, chunkSize: Self.chunkSize)
        var bytes = Data()
        try compressor.write(Data(), finish: true) { bytes.append($0) }
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(bytes[12..<16], Data(repeating: 0, count: 4))
        try bytes.write(to: url)
        let xz = try XCTUnwrap(try tool(["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]))
        try ZipTestSupport.run(xz, ["-t", url.path], in: directory, log: "xz-test")
        let listing = try ZipTestSupport.run(xz, ["-l", "--robot", url.path], in: directory, log: "xz-list")
        XCTAssertTrue(listing.contains("file\t1\t0\t"), listing)
    }

    func testCancellationDuringSevenZipMultiChunkAdd() async throws {
        try await cancellation(format: .sevenZip)
    }

    func testCancellationDuringTarXZFinish() async throws {
        try await cancellation(format: .tarXZ)
    }

    func testDeferredFailureFromLaterAddOrFinishInvalidatesWriter() throws {
        let directory = try ZipTestSupport.directory("parallel-lzma-error")
        for useFinish in [false, true] {
            let url = directory.appendingPathComponent("\(useFinish).7z")
            let writer = try ArchiveWriter.create(url: url, format: .sevenZip, options: WriterOptions(compressionThreads: 1),
                                                 lzmaChunkSize: Self.chunkSize) { _ in throw WriterError.compression(-77) }
            try writer.add(data: Data([1]), as: "first")
            XCTAssertThrowsError(try useFinish ? writer.finish() : writer.add(data: Data([2]), as: "second")) {
                XCTAssertEqual($0 as? WriterError, .compression(-77))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
        }
    }

    func testCompressionThreadsValidationAndAutomaticLimit() throws {
        let directory = try ZipTestSupport.directory("parallel-lzma-options")
        XCTAssertNil(WriterOptions().compressionThreads)
        XCTAssertEqual(WriterOptions().resolvedCompressionThreads,
                       max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8,
                                  Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)))))
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha] {
            for threads in [Int.min, 0, 65, Int.max] {
                let url = directory.appendingPathComponent("\(format)-\(threads)")
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format,
                                                              options: WriterOptions(compressionThreads: threads))) {
                    XCTAssertEqual($0 as? WriterError, .invalidOption("compressionThreads"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            for threads in [1, 64] { XCTAssertNoThrow(try WriterOptions(compressionThreads: threads).validate(for: format)) }
        }
    }

    private func cancellation(format: GyoshukuKit.ArchiveFormat) async throws {
        let directory = try ZipTestSupport.directory("parallel-cancel-\(format)")
        let url = directory.appendingPathComponent("archive")
        let alias = directory.appendingPathComponent("alias")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let writer = try ArchiveWriter.create(url: url, format: format, options: WriterOptions(compressionThreads: 1),
                                                 lzmaChunkSize: Self.chunkSize) { input in
                started.signal()
                // 取消し処理が退行してもテストを永久に待たせない。
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return try LZMA2Compressor.encode(input)
            }
            try FileManager.default.linkItem(at: url, to: alias)
            let count = format == .sevenZip ? 3 * Self.chunkSize : Self.chunkSize / 2
            try writer.add(data: Data(repeating: 0x41, count: count), as: "file")
            try writer.finish()
        }
        defer { release.signal() }
        try await LZMA2ChunkPipelineTests.wait(started)
        let start = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("cancelled writer succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let latency = start.duration(to: .now)
        XCTAssertLessThan(latency, .milliseconds(250))
        ZipTestSupport.report("PARALLEL CANCELLATION \(format): \(latency)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: alias).count, 0)
    }

    private static var tarItems: [SevenZipTestSupport.Expected] {
        [.init(name: "large.txt", data: payload), .init(name: "empty"), .init(name: "last", data: Data("last tar member".utf8))]
    }

    private func tarXZ(in directory: URL, threads: Int = 8) throws -> URL {
        let url = directory.appendingPathComponent("threads-\(threads).tar.xz")
        let writer = try ArchiveWriter.create(url: url, format: .tarXZ,
                                             options: WriterOptions(compressionThreads: threads), lzmaChunkSize: Self.chunkSize)
        for item in Self.tarItems { try writer.add(data: item.data, as: item.name, modificationDate: ZipTestSupport.date) }
        try writer.finish()
        return url
    }

    private func verify(_ url: URL, items: [SevenZipTestSupport.Expected], password: String? = nil) throws {
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), items.map(\.name))
        for (entry, item) in zip(reader.entries, items) {
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
        }
    }

    // 変更前の直列連結を基準にし、thread 数が同じ誤りを共有しても検出する。
    private func serialArchive(_ items: [SevenZipTestSupport.Expected]) throws -> Data {
        var payload = Data(), entries: [SevenZipRecords.Entry] = []
        for item in items {
            var entry = SevenZipRecords.Entry(name: item.name, mode: (item.kind == .directory ? 0o40000 : 0o100000) | item.mode,
                                               size: UInt64(item.data.count), mtime: try SevenZipRecords.timestamp(ZipTestSupport.date))
            let start = payload.count
            for offset in stride(from: 0, to: item.data.count, by: Self.chunkSize) {
                let chunk = item.data[offset..<min(offset + Self.chunkSize, item.data.count)]
                let compressed = try LZMA2Compressor.encode(chunk)
                payload.append(compressed.payload.dropLast())
                entry.properties = max(entry.properties, compressed.properties)
                entry.crc = updateCRC(entry.crc, chunk)
            }
            if !item.data.isEmpty { payload.append(0) }
            entry.packedSize = UInt64(payload.count - start)
            entry.compressedSize = entry.packedSize
            entries.append(entry)
        }
        let header = try SevenZipRecords.header(entries)
        return SevenZipRecords.signature(packedSize: UInt64(payload.count), header: header) + payload + header
    }

    private func tool(_ candidates: [String]) throws -> String? {
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Reference tool missing: \(candidates.joined(separator: ", "))")
        }
        return executable
    }
}
