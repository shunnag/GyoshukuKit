import Foundation
import Darwin
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ParallelDeflateBzip2WriterTests: XCTestCase {
    private static let blockSize = 64 * 1024
    private static let password = EncryptionTestSupport.password
    private static var payload: Data {
        let seed = LHATestSupport.random(16 * 1024)
            + Data(String(repeating: "parallel deflate and bzip2\n", count: 700).utf8)
        var result = Data()
        while result.count < 7 * 1024 * 1024 / 2 { result.append(seed) }
        return Data(result.prefix(7 * 1024 * 1024 / 2))
    }

    private struct Item {
        let name: String
        let data: Data
        var mode: UInt16 = 0o100644
    }

    private static var items: [Item] {
        [.init(name: "large", data: payload),
         .init(name: "small", data: Data("small member".utf8)),
         .init(name: "stored.PNG", data: LHATestSupport.random(8_123)),
         .init(name: "empty", data: Data()),
         .init(name: "directory/", data: Data(), mode: 0o40755),
         .init(name: "link", data: Data("small".utf8), mode: 0o120755),
         .init(name: "last", data: Data("last member".utf8))]
    }

    private static var bzip2Items: [Item] {
        let chunkSize = ParallelBzip2Compressor.chunkSize(level: 9)
        let seed = payload
        var data = Data()
        while data.count < 2 * chunkSize + 137 { data.append(seed) }
        return [.init(name: "large", data: Data(data.prefix(2 * chunkSize + 137)))] + items.dropFirst()
    }

    static func addProgressFixture(to writer: ArchiveWriter) throws {
        try add(items.filter { writer.format != .lha || !$0.mode.isSymlinkMode }, to: writer)
    }

    func testZIPThreadCountsAndAESAreByteIdenticalAtLevels6And9() throws {
        let directory = try TestSupport.directory("m8-zip-determinism")
        for level in [6, 9] {
            for encrypted in [false, true] {
                var expected: Data?
                for (threads, drain) in [(1, false), (4, false), (8, false), (1, true), (8, true)] {
                    let url = directory.appendingPathComponent("\(level)-\(encrypted)-\(threads)-\(drain).zip")
                    let options = WriterOptions(deflateLevel: level, password: encrypted ? Self.password : nil,
                                                compressionThreads: threads)
                    let writer = try Self.writer(url, format: .zip, options: options)
                    try Self.add(Self.items, to: writer)
                    if drain { try writer.finishAdditions(progress: { _ in }) }
                    try writer.finish()
                    let data = try Data(contentsOf: url)
                    if let expected { XCTAssertEqual(data, expected) } else { expected = data }
                    try Self.verify(url, items: Self.items, password: options.password)
                    let bytes = ZipBytes(data: data)
                    XCTAssertEqual(bytes.u16(6), encrypted ? 0x0801 : 0x0800)
                    XCTAssertNil(bytes.extras(0, local: true)[1])
                }
            }
        }
    }

    func testManySeparateDiskAddsStayInOrderAcrossThreadCounts() throws {
        let directory = try TestSupport.directory("m8-small-disk-files")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let items = (0..<160).map { index in
            Item(name: index % 31 == 0 ? "stored-\(index).png" : "file-\(index)",
                 data: index % 37 == 0 ? Data() : Data(String(repeating: "entry \(index)\n", count: 80).utf8))
        }
        for item in items { try item.data.write(to: source.appendingPathComponent(item.name)) }
        var expected: Data?
        for threads in [1, 4, 8] {
            let url = directory.appendingPathComponent("\(threads).zip")
            let writer = try Self.writer(url, format: .zip, options: WriterOptions(compressionThreads: threads))
            for item in items {
                let file = source.appendingPathComponent(item.name)
                var times = [timeval(tv_sec: 1_700_000_001, tv_usec: 0), timeval(tv_sec: 1_700_000_001, tv_usec: 0)]
                XCTAssertEqual(utimes(file.path, &times), 0)
                try writer.add(contentsOf: file, as: item.name)
            }
            try writer.finish()
            let data = try Data(contentsOf: url)
            if let expected { XCTAssertEqual(data, expected) } else { expected = data }
            try Self.verify(url, items: items)
        }
    }

    func testTarThreadCountsAreByteIdentical() throws {
        let directory = try TestSupport.directory("m8-tar-determinism")
        for format: GyoshukuKit.ArchiveFormat in [.tarGzip, .tarBzip2] {
            let items = format == .tarBzip2 ? Self.bzip2Items : Self.items
            for level in format == .tarGzip ? [6, 9] : [1, 9] {
                var expected: Data?
                for (threads, drain) in [(1, false), (4, false), (8, false), (1, true), (8, true)] {
                    let url = directory.appendingPathComponent("\(format)-\(level)-\(threads)-\(drain).tar.\(format == .tarGzip ? "gz" : "bz2")")
                    let writer = try Self.writer(url, format: format,
                        options: WriterOptions(deflateLevel: level, bzip2Level: level, compressionThreads: threads))
                    try Self.add(items, to: writer)
                    if drain { try writer.finishAdditions(progress: { _ in }) }
                    try writer.finish()
                    let data = try Data(contentsOf: url)
                    if let expected { XCTAssertEqual(data, expected) } else { expected = data }
                    try Self.verify(url, items: items)
                }
            }
        }
    }

    func testUnzipIntegrityAndPayload() throws {
        let tool = try ReferenceTool.require([ReferenceTool.unzip, "/opt/homebrew/bin/unzip"])
        let url = try fixture("unzip", format: .zip)
        try TestSupport.run(tool, ["-t", url.path], in: url.deletingLastPathComponent(), log: "test")
        for (index, item) in Self.items.enumerated() where !item.mode.isDirectoryMode {
            XCTAssertEqual(try Self.stdout(tool, ["-p", url.path, item.name], beside: url, name: "payload-\(index)"), item.data)
        }
    }

    func testDittoExtraction() throws {
        let tool = try ReferenceTool.require([ReferenceTool.ditto])
        let url = try fixture("ditto", format: .zip)
        let extracted = url.deletingLastPathComponent().appendingPathComponent("extracted")
        try TestSupport.run(tool, ["-x", "-k", url.path, extracted.path], in: url.deletingLastPathComponent(), log: "extract")
        try Self.verifyExtracted(extracted, items: Self.items)
    }

    func testBSDTarExtractionForEveryFormat() throws {
        let tool = try ReferenceTool.require([ReferenceTool.bsdtar, ReferenceTool.tar, "/opt/homebrew/bin/bsdtar"])
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .tarBzip2] {
            let url = try fixture("bsdtar-\(format)", format: format)
            let extracted = url.deletingLastPathComponent().appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try TestSupport.run(tool, ["-xf", url.path, "-C", extracted.path], in: url.deletingLastPathComponent(), log: "extract")
            try Self.verifyExtracted(extracted, items: format == .tarBzip2 ? Self.bzip2Items : Self.items)
        }
    }

    func testSevenZipIntegrityAndAESExtraction() throws {
        let tool = try ReferenceTool.require([ReferenceTool.sevenZip, "/usr/local/bin/7zz"])
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .tarBzip2] {
            let url = try fixture("7zz-\(format)", format: format)
            try TestSupport.run(tool, ["t", url.path], in: url.deletingLastPathComponent(), log: "test")
        }
        let url = try fixture("7zz-aes", format: .zip, encrypted: true)
        let directory = url.deletingLastPathComponent()
        try TestSupport.run(tool, ["t", "-p\(Self.password)", url.path], in: directory, log: "test")
        let extracted = directory.appendingPathComponent("extracted")
        try TestSupport.run(tool, ["x", "-y", "-p\(Self.password)", "-o\(extracted.path)", url.path], in: directory, log: "extract")
        try Self.verifyExtracted(extracted, items: Self.items)
    }

    func testGzipIntegrityAndSingleMemberTrailer() throws {
        let gzip = try ReferenceTool.require([ReferenceTool.gzip, "/opt/homebrew/bin/gzip"])
        let python = try ReferenceTool.require([ReferenceTool.python3, "/opt/homebrew/bin/python3"])
        let url = try fixture("gzip", format: .tarGzip)
        try TestSupport.run(gzip, ["-t", url.path], in: url.deletingLastPathComponent(), log: "test")
        let script = """
        import sys,zlib,struct
        b=open(sys.argv[1],'rb').read()
        assert b[:10]==bytes([31,139,8,0,0,0,0,0,2,3])
        d=zlib.decompressobj(31); raw=d.decompress(b)+d.flush()
        assert d.eof and not d.unused_data
        assert struct.unpack('<II',b[-8:])==(zlib.crc32(raw),len(raw)%(1<<32))
        sys.stdout.buffer.write(raw)
        """
        let raw = try Self.stdout(python, ["-c", script, url.path], beside: url, name: "raw.tar")
        try verifyRawTar(raw, beside: url, items: Self.items)
    }

    func testBzip2IntegrityAndConcatenatedStreamSizes() throws {
        let bzip2 = try ReferenceTool.require([ReferenceTool.bzip2, "/opt/homebrew/bin/bzip2"])
        let python = try ReferenceTool.require([ReferenceTool.python3, "/opt/homebrew/bin/python3"])
        let url = try fixture("bzip2", format: .tarBzip2)
        try TestSupport.run(bzip2, ["-t", url.path], in: url.deletingLastPathComponent(), log: "test")
        let script = """
        import sys,bz2
        b=open(sys.argv[1],'rb').read(); whole=bz2.decompress(b); parts=[]
        while b:
            assert b[:4]==b'BZh9'
            d=bz2.BZ2Decompressor(); parts.append(d.decompress(b)); assert d.eof
            b=d.unused_data
        assert [len(p) for p in parts] == \(try TarChunkLayoutTestSupport.expectedLengths(url, format: .tarBzip2, limit: 4_500_000))
        assert 0<len(parts[-1])<=4500000 and b''.join(parts)==whole
        sys.stdout.buffer.write(whole)
        """
        let raw = try Self.stdout(python, ["-c", script, url.path], beside: url, name: "raw.tar")
        try verifyRawTar(raw, beside: url, items: Self.bzip2Items)
    }

    func testUpdaterAndRewriterZIPOutputUsesParallelFormat() throws {
        let directory = try TestSupport.directory("m8-edit-shared-writer")
        var updated: Data?, rewritten: Data?
        let items = Self.items.filter { $0.mode.isRegularFileMode }
        for threads in [1, 4, 8] {
            let options = WriterOptions(deflateLevel: 9, compressionThreads: threads)
            let zip = directory.appendingPathComponent("update-\(threads).zip")
            try ArchiveWriter.create(url: zip).finish()
            let updater = try ArchiveUpdater.open(url: zip, options: options)
            for item in items { try updater.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
            try updater.commit()
            let bytes = try Data(contentsOf: zip)
            if let updated { XCTAssertEqual(bytes, updated) } else { updated = bytes }
            try Self.verify(zip, items: items)
            let tar = directory.appendingPathComponent("source-\(threads).tar")
            let writer = try ArchiveWriter.create(url: tar, format: .tar)
            try Self.add(items, to: writer)
            try writer.finish()
            let output = directory.appendingPathComponent("rewrite-\(threads).zip")
            let rewriter = try ArchiveRewriter.open(url: tar, output: output, format: .zip, options: options)
            try rewriter.commit()
            let result = try Data(contentsOf: output)
            if let rewritten { XCTAssertEqual(result, rewritten) } else { rewritten = result }
            try Self.verify(output, items: items)
        }
    }

    func testShortReadsDoNotChangeDeflateBoundaries() throws {
        let directory = try TestSupport.directory("m8-short-read")
        let source = directory.appendingPathComponent("source")
        let data = Self.payload
        try data.write(to: source)
        var expected: Data?
        for short in [false, true] {
            let url = directory.appendingPathComponent("\(short).zip")
            let writer = try Self.writer(url, format: .zip)
            var offset = 0
            try writer.add(contentsOf: source, as: "file") { _, requested in
                let count = min(short ? 997 : requested, requested, data.count - offset)
                defer { offset += count }
                return data.subdata(in: offset..<(offset + count))
            }
            try writer.finish()
            let bytes = try Data(contentsOf: url)
            if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
            try Self.verify(url, items: [.init(name: "file", data: data)])
        }
    }

    private func fixture(_ label: String, format: GyoshukuKit.ArchiveFormat, encrypted: Bool = false) throws -> URL {
        let directory = try TestSupport.directory("m8-external-\(label)")
        let url = directory.appendingPathComponent("archive")
        let writer = try Self.writer(url, format: format,
            options: WriterOptions(deflateLevel: 9, password: encrypted ? Self.password : nil, compressionThreads: 4))
        try Self.add(format == .tarBzip2 ? Self.bzip2Items : Self.items, to: writer)
        try writer.finish()
        return url
    }

    private static func writer(_ url: URL, format: GyoshukuKit.ArchiveFormat,
                               options: WriterOptions = WriterOptions()) throws -> ArchiveWriter {
        try ArchiveWriter.create(url: url, format: format, options: options, deflateBlockSize: blockSize,
                                 zipSalt: { Data(0..<16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
    }

    private static func add(_ items: [Item], to writer: ArchiveWriter) throws {
        for item in items {
            var offset = 0
            try writer.addEntry(path: item.name, mode: item.mode, size: UInt64(item.data.count),
                                date: TestSupport.date, atime: nil, owners: nil) { requested in
                let count = min(requested, item.data.count - offset)
                defer { offset += count }
                return item.data.subdata(in: offset..<(offset + count))
            }
        }
    }

    private static func verify(_ url: URL, items: [Item], password: String? = nil) throws {
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), items.map(\.name))
        for (entry, item) in zip(reader.entries, items) {
            if reader.format == .tar && entry.kind == .symlink {
                XCTAssertEqual(entry.formatSpecific["linkPath"], String(decoding: item.data, as: UTF8.self))
            } else { XCTAssertEqual(try reader.read(entry), item.data, item.name) }
        }
    }

    private static func verifyExtracted(_ directory: URL, items: [Item]) throws {
        for item in items {
            let path = directory.appendingPathComponent(item.name)
            if item.mode.isDirectoryMode {
                var isDirectory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory))
                XCTAssertTrue(isDirectory.boolValue)
            } else if item.mode.isSymlinkMode {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), String(decoding: item.data, as: UTF8.self))
            } else {
                XCTAssertEqual(try Data(contentsOf: path), item.data)
            }
        }
    }

    private func verifyRawTar(_ data: Data, beside url: URL, items: [Item]) throws {
        let raw = url.deletingLastPathComponent().appendingPathComponent("expected.tar")
        let writer = try ArchiveWriter.create(url: raw, format: .tar)
        try Self.add(items, to: writer)
        try writer.finish()
        XCTAssertEqual(data, try Data(contentsOf: raw))
    }

    /// stdout を `url` の隣の `name` に書かせて返す。stderr は `name.log` に残す。
    private static func stdout(_ tool: String, _ arguments: [String], beside url: URL, name: String) throws -> Data {
        try ReferenceTool.run(tool, arguments, in: url.deletingLastPathComponent(), log: name,
                              environment: [:], standardOutput: name).bytes
    }
}
