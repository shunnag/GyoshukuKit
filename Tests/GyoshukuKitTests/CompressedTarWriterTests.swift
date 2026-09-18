import CryptoKit
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class CompressedTarWriterTests: XCTestCase {
    private let formats: [GyoshukuKit.ArchiveFormat] = [.tarBzip2, .tarXZ]

    private func suffix(_ format: GyoshukuKit.ArchiveFormat) -> String {
        format == .tarBzip2 ? "bz2" : "xz"
    }

    // Independent liblzma/Python and 7-Zip decode the entire compressed stream;
    // compare its exact bytes, including tar metadata, padding and end markers.
    private func verifyStream(_ archive: URL, expected: Data, format: GyoshukuKit.ArchiveFormat) throws {
        let directory = archive.deletingLastPathComponent()
        let decoded = directory.appendingPathComponent("decoded.tar")
        let script = """
        import bz2,lzma,pathlib,sys
        source,target,kind=sys.argv[1:]
        payload=(bz2 if kind=='bz2' else lzma).decompress(pathlib.Path(source).read_bytes())
        pathlib.Path(target).write_bytes(payload)
        print(len(payload))
        """
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, archive.path, decoded.path, suffix(format)],
                               in: directory, log: "python-stream")
        XCTAssertEqual(try Data(contentsOf: decoded), expected)
        try ZipTestSupport.run(format == .tarBzip2 ? "/usr/bin/bzip2" : "/opt/homebrew/bin/xz",
                               ["-t", archive.path], in: directory, log: "native-stream")
        let output = directory.appendingPathComponent("seven-stream")
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["x", "-y", archive.path, "-o" + output.path],
                               in: directory, log: "seven-stream")
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), expected)
    }

    func testMultipleMembersPreserveExactTarBytesAndExternalExtraction() throws {
        let items: [TarTestSupport.Expected] = [
            .init(name: "日本語/資料.txt", data: Data(repeating: 0x61, count: 550_123), permissions: 0o640),
            .init(name: "binary", data: LHATestSupport.random(1_600_123)),
            .init(name: String(repeating: "n", count: 130), data: Data([0, 255, 1])),
            .init(name: "empty")
        ]
        for format in formats {
            let directory = try ZipTestSupport.directory("compressed-tar-members-\(format)")
            let archive = directory.appendingPathComponent("archive.tar." + suffix(format))
            let plain = directory.appendingPathComponent("plain.tar")
            for (url, kind) in [(archive, format), (plain, .tar)] {
                let writer = try ArchiveWriter.create(url: url, format: kind)
                for item in items {
                    try writer.add(data: item.data, as: item.name, modificationDate: item.date, permissions: item.permissions)
                }
                try writer.finish()
            }
            let expected = try Data(contentsOf: plain)
            _ = try TarBytes(expected)
            try verifyStream(archive, expected: expected, format: format)
            try TarTestSupport.verify(archive, expected: items)
            let sevenEntries = directory.appendingPathComponent("seven-entries")
            try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["x", "-y", directory.appendingPathComponent("decoded.tar").path,
                                   "-o" + sevenEntries.path], in: directory, log: "seven-entries")
            for item in items { XCTAssertEqual(try Data(contentsOf: sevenEntries.appendingPathComponent(item.name)), item.data) }
        }
    }

    func testEmptyAndTarBlockBoundaries() throws {
        for format in formats {
            for size in [nil, 0, 1, 511, 512, 513, 8_704, 8_705, 9_216] as [Int?] {
                let directory = try ZipTestSupport.directory("compressed-tar-boundary-\(format)-\(size ?? -1)")
                let archive = directory.appendingPathComponent("archive.tar." + suffix(format))
                let plain = directory.appendingPathComponent("plain.tar")
                for (url, kind) in [(archive, format), (plain, .tar)] {
                    let writer = try ArchiveWriter.create(url: url, format: kind)
                    if let size { try writer.add(data: Data(repeating: 0x41, count: size), as: "file", modificationDate: ZipTestSupport.date) }
                    try writer.finish()
                }
                try verifyStream(archive, expected: Data(contentsOf: plain), format: format)
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.count, size == nil ? 0 : 1)
                if let size { XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), Data(repeating: 0x41, count: size)) }
            }
        }
    }

    func testBzip2LevelsAndInvalidOptionsBeforeCreatingOutput() throws {
        let directory = try ZipTestSupport.directory("compressed-tar-levels")
        for level in 1...9 {
            let archive = directory.appendingPathComponent("level\(level).tar.bz2")
            let writer = try ArchiveWriter.create(url: archive, format: .tarBzip2, options: WriterOptions(bzip2Level: level))
            try writer.add(data: LHATestSupport.random(190_123), as: "file")
            try writer.finish()
            XCTAssertEqual(try Data(contentsOf: archive).prefix(4), Data("BZh\(level)".utf8))
            try ZipTestSupport.run("/usr/bin/bzip2", ["-t", archive.path], in: directory, log: "level-\(level)")
        }
        XCTAssertEqual(WriterOptions().bzip2Level, 9)
        for level in [Int.min, 0, 10, Int.max] {
            let output = directory.appendingPathComponent("invalid-\(level)")
            XCTAssertThrowsError(try ArchiveWriter.create(url: output, format: .tarBzip2, options: WriterOptions(bzip2Level: level))) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("bzip2Level"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testTinyWritesAndLargeFinalInputDrainAllOutput() throws {
        let input = LHATestSupport.random(1_200_123)
        for format in formats {
            for chunk in [1, 3, 37, 262_144] {
                let directory = try ZipTestSupport.directory("compressed-tar-chunks-\(format)-\(chunk)")
                let archive = directory.appendingPathComponent("stream." + suffix(format))
                let compressor: any TarCompressor = format == .tarBzip2 ? try Bzip2Compressor(level: 1) : try XZCompressor()
                var encoded = Data()
                // Exercise tiny input across native calls, then a final input larger than the output buffer.
                for offset in stride(from: 0, to: 30_001, by: chunk) {
                    try compressor.write(input.subdata(in: offset..<min(offset + chunk, 30_001)), finish: false) { encoded.append($0) }
                }
                try compressor.write(input.subdata(in: 30_001..<input.count), finish: true) { encoded.append($0) }
                XCTAssertThrowsError(try compressor.write(Data(), finish: true) { _ in })
                try encoded.write(to: archive)
                try verifyStream(archive, expected: input, format: format)
            }
        }
    }

    func testCancellationDuringCompressedPayloadRemovesOutput() async throws {
        for format in formats {
            let directory = try ZipTestSupport.directory("compressed-tar-cancel-\(format)")
            let source = directory.appendingPathComponent("source")
            FileManager.default.createFile(atPath: source.path, contents: LHATestSupport.random(16 * 1_024 * 1_024))
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
            try handle.close()
            defer { try? FileManager.default.removeItem(at: source) }
            let archive = directory.appendingPathComponent("archive.tar." + suffix(format))
            let task = Task.detached {
                let writer = try ArchiveWriter.create(url: archive, format: format)
                try writer.add(contentsOf: source, as: "large")
                try writer.finish()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var observedPayload = false
            while ContinuousClock.now < deadline {
                let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 262_144 { observedPayload = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let cancellation = ContinuousClock.now
            task.cancel()
            do { try await task.value; XCTFail("cancelled write succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertTrue(observedPayload, "must cancel during actual payload output")
            XCTAssertLessThan(cancellation.duration(to: .now), .seconds(3))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    // Opt in on a disk with at least 6 GiB free. Exercise a real public writer
    // and an entry beyond UInt32.max; the source is sparse, the read is bounded.
    func testEntryLargerThanFourGiBThroughPublicWriterAndIndependentReaders() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_LARGE_TAR_TESTS"] == "1" else {
            throw XCTSkip("Set GYOSHUKU_LARGE_TAR_TESTS=1 for the 4 GiB streaming check")
        }
        let directory = try ZipTestSupport.directory("compressed-tar-four-gib")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let length = UInt64(UInt32.max) + 514
        let prefix = Data("first bytes".utf8), suffix = Data("bytes beyond four GiB".utf8)
        try prefix.write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: length)
        try handle.seek(toOffset: length - UInt64(suffix.count))
        try handle.write(contentsOf: suffix)
        try handle.close()
        let script = """
        import hashlib,sys,tarfile
        archive,source=sys.argv[1:]
        h=hashlib.sha256();count=0
        with open(source,'rb') as original,tarfile.open(archive,'r|*') as tar:
            member=tar.next()
            assert member.name=='large' and member.size==4294967809,member
            with tar.extractfile(member) as decoded:
                while True:
                    a=original.read(1024*1024);b=decoded.read(1024*1024)
                    assert a==b,('mismatch at',count)
                    if not a:break
                    h.update(b);count+=len(b)
            assert tar.next().name=='after'
            assert tar.next() is None
        print(count,h.hexdigest())
        """
        for format in formats {
            let archive = directory.appendingPathComponent("archive.tar." + self.suffix(format))
            let writer = try ArchiveWriter.create(url: archive, format: format)
            try writer.add(contentsOf: source, as: "large")
            try writer.add(data: Data("after large entry".utf8), as: "after")
            try writer.finish()
            let oracle = try ZipTestSupport.run("/usr/bin/python3", ["-c", script, archive.path, source.path],
                                                in: directory, log: "large-python-\(format)")
            let referenceHash = try XCTUnwrap(oracle.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
            let listing = try ZipTestSupport.run("/usr/bin/bsdtar", ["-tf", archive.path], in: directory, log: "large-bsdtar-\(format)")
            XCTAssertEqual(listing, "large\nafter\n")
            try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", archive.path], in: directory, log: "large-seven-\(format)")
            // A raised explicit limit is required; the application's default stays 4 GiB.
            let limits = ReadLimits(maxEntrySize: length + 1_048_576, maxTotalUncompressedSize: length + 1_048_576,
                                    maxInMemorySize: 1_048_576, inMemorySingleFileLimit: 1_048_576)
            let reader = try ArchiveReader.open(url: archive, options: ReaderOptions(limits: limits))
            XCTAssertEqual(reader.entries.map(\.name), ["large", "after"])
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(entry.uncompressedSize, length)
            let stream = try reader.stream(entry)
            var buffer = [UInt8](repeating: 0, count: 262_144), hash = SHA256(), read: UInt64 = 0
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                read += UInt64(count)
            }
            XCTAssertEqual(read, length)
            XCTAssertEqual(hash.finalize().map { String(format: "%02x", $0) }.joined(), referenceHash)
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("after large entry".utf8))
        }
    }

}
