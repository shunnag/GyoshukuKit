import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class GzipWriterTests: XCTestCase {
    func testGzipHeaderTrailerLevelsAndExternalRoundTrip() throws {
        // 圧縮されにくい入力で複数の出力 chunk を通す。乱数 seed は固定して再現可能にする。
        var value: UInt64 = 0x12345678
        let payload = Data((0..<800_003).map { _ in
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            return UInt8(truncatingIfNeeded: value)
        })
        for level in [0, 1, 6, 9] {
            let directory = try ZipTestSupport.directory("gzip-level-\(level)")
            let url = directory.appendingPathComponent("archive.tar.gz")
            let writer = try ArchiveWriter.create(url: url, format: .tarGzip, options: WriterOptions(deflateLevel: level))
            try writer.add(data: payload, as: "payload.bin", modificationDate: ZipTestSupport.date)
            try writer.add(data: Data(), as: "empty", modificationDate: ZipTestSupport.date)
            try writer.finish()
            let data = try Data(contentsOf: url)
            // ID1/ID2, CM=deflate, FLG=0, MTIME=0, XFL は zlib の level、OS=Unix。
            XCTAssertEqual(Data(data.prefix(10)), Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, level == 9 ? 2 : (level <= 1 ? 4 : 0), 3]))
            try TarTestSupport.verify(url, expected: [.init(name: "payload.bin", data: payload), .init(name: "empty")], gzip: true)
            let script = """
            import gzip,struct,sys,zlib
            b=open(sys.argv[1],'rb').read(); raw=gzip.decompress(b)
            crc,size=struct.unpack('<II',b[-8:])
            assert crc==zlib.crc32(raw) and size==len(raw) % (1<<32)
            open(sys.argv[2],'wb').write(raw)
            print('gzip CRC32 and ISIZE match; tar bytes',len(raw))
            """
            let rawURL = directory.appendingPathComponent("raw.tar")
            let output = try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path, rawURL.path], in: directory, log: "python-gzip-trailer")
            let raw = try Data(contentsOf: rawURL)
            XCTAssertEqual(output, "gzip CRC32 and ISIZE match; tar bytes \(raw.count)\n")
            let bytes = try TarBytes(raw)
            XCTAssertEqual(bytes.records.map(\.type), [0x30, 0x30])
            XCTAssertEqual(bytes.records[0].payload, payload)
            let seven = try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", rawURL.path], in: directory, log: "7zz-t-inner-tar")
            XCTAssertTrue(seven.contains("Everything is Ok"))
        }
    }

    func testEmptyGzipArchive() throws {
        let directory = try ZipTestSupport.directory("gzip-empty")
        let url = directory.appendingPathComponent("archive.tar.gz")
        let writer = try ArchiveWriter.create(url: url, format: .tarGzip)
        try writer.finish()
        try TarTestSupport.verify(url, expected: [], gzip: true)
    }

    func testGzipPaxAndSlicedData() throws {
        let directory = try ZipTestSupport.directory("gzip-pax")
        let url = directory.appendingPathComponent("archive.tar.gz")
        let name = String(repeating: "日本語", count: 12)
        let data = Data([0, 1, 2, 3, 4]).dropFirst(2)
        XCTAssertNotEqual(data.startIndex, 0)
        let writer = try ArchiveWriter.create(url: url, format: .tarGzip)
        try writer.add(data: data, as: name, modificationDate: ZipTestSupport.date, permissions: 0o750)
        try writer.finish()
        try TarTestSupport.verify(url, expected: [.init(name: name, data: Data([2, 3, 4]), permissions: 0o750)], gzip: true)
    }

    func testInvalidOptionsAndDateLeaveNoArchive() throws {
        let directory = try ZipTestSupport.directory("gzip-invalid")
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let url = directory.appendingPathComponent("\(format).tar.gz")
            for options in [WriterOptions(deflateLevel: -1), WriterOptions(deflateLevel: 10), WriterOptions(preserveMacOSMetadata: true)] {
                XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format, options: options))
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            let writer = try ArchiveWriter.create(url: url, format: format)
            XCTAssertThrowsError(try writer.add(data: Data(), as: "invalid", modificationDate: Date(timeIntervalSince1970: .infinity))) {
                XCTAssertEqual($0 as? WriterError, .invalidDate)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// bsdtar と record 構造・pax 判断・pax 本文まで一致することを確かめる。
    /// 外部ツールが「読める」だけでは、いつ pax を出すかの判断が同じとは言えない。
    func testTarRecordLayoutMatchesBsdtarByteForByte() throws {
        let directory = try ZipTestSupport.directory("tar-vs-bsdtar")
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let files = ["a.txt": Data("hello world".utf8), "日本語.txt": Data("にほんご".utf8),
                     "sub/b.bin": Data([0x00, 0x01, 0x02, 0xFF])]
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = source.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date,
                                                   .posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        let ours = directory.appendingPathComponent("ours.tar")
        let writer = try ArchiveWriter.create(url: ours, format: .tar)
        for name in ["a.txt", "日本語.txt", "sub/b.bin"] {
            try writer.add(contentsOf: source.appendingPathComponent(name), as: name)
        }
        try writer.finish()

        let theirs = directory.appendingPathComponent("theirs.tar")
        _ = try ZipTestSupport.run("/usr/bin/bsdtar",
            ["--no-mac-metadata", "--no-xattrs", "--uid", "0", "--gid", "0",
             "--uname", "", "--gname", "", "-cf", theirs.path, "-C", source.path,
             "a.txt", "日本語.txt", "sub/b.bin"], in: directory, log: "bsdtar-c")

        // 数値フィールドの終端(NUL / 空白)と末尾 padding 量は POSIX がどちらも許すため
        // 比較しない。同じであるべきなのは、どの member をどの型で出すかと pax の中身。
        let mine = try TarBytes(Data(contentsOf: ours)), reference = try TarBytes(Data(contentsOf: theirs), blocking: 512)
        XCTAssertEqual(mine.records.map { String(decoding: $0.name, as: UTF8.self) },
                       reference.records.map { String(decoding: $0.name, as: UTF8.self) })
        XCTAssertEqual(mine.records.map(\.type), reference.records.map(\.type))
        XCTAssertEqual(mine.records.map(\.payload), reference.records.map(\.payload))
    }
}
