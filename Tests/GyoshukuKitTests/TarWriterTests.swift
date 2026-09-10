import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class TarWriterTests: XCTestCase {
    func testSimpleArchiveExternalToolsAndKaitoRoundTrip() throws {
        let directory = try ZipTestSupport.directory("tar-simple")
        let url = directory.appendingPathComponent("archive.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        XCTAssertEqual(writer.format, .tar)
        let items: [TarTestSupport.Expected] = [
            .init(name: "hello.txt", data: Data("hello tar\n".utf8)),
            .init(name: "nested/binary", data: Data((0..<200_003).map { UInt8(truncatingIfNeeded: $0) })),
            .init(name: "empty")
        ]
        for item in items { try writer.add(data: item.data, as: item.name, modificationDate: item.date) }
        try writer.finish()
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.records.map(\.type), [0x30, 0x30, 0x30])
        for record in bytes.records {
            XCTAssertTrue(record.header[265..<329].allSatisfy { $0 == 0 })
            XCTAssertEqual(String(decoding: record.header[108..<115], as: UTF8.self), "0000000")
            XCTAssertEqual(String(decoding: record.header[116..<123], as: UTF8.self), "0000000")
        }
        try TarTestSupport.verify(url, expected: items)
    }

    func testEmptyArchiveAndBlockingFactorBoundaries() throws {
        for (index, size) in [nil, 0, 1, 511, 512, 513, 8_704, 8_705, 9_216].enumerated() {
            let directory = try ZipTestSupport.directory("tar-block-\(index)")
            let url = directory.appendingPathComponent("archive.tar")
            let writer = try ArchiveWriter.create(url: url, format: .tar)
            if let size { try writer.add(data: Data(repeating: 0x41, count: size), as: "file", modificationDate: ZipTestSupport.date) }
            try writer.finish()
            let data = try Data(contentsOf: url)
            let bytes = try TarBytes(data)
            let used = size.map { 512 + (($0 + 511) / 512) * 512 } ?? 0
            XCTAssertEqual(bytes.endOffset, used)
            XCTAssertEqual(data.count, ((used + 1024 + 10_239) / 10_240) * 10_240)
            if size == nil { try TarTestSupport.verify(url, expected: []) }
        }
    }

    func testExactly100ByteNameAnd101BytePaxPath() throws {
        for length in [100, 101] {
            let directory = try ZipTestSupport.directory("tar-name-\(length)")
            let url = directory.appendingPathComponent("archive.tar")
            let name = String(repeating: "n", count: length)
            let writer = try ArchiveWriter.create(url: url, format: .tar)
            try writer.add(data: Data([1]), as: name, modificationDate: ZipTestSupport.date)
            try writer.finish()
            let bytes = try TarBytes(Data(contentsOf: url))
            XCTAssertEqual(bytes.records.map(\.type), length == 100 ? [0x30] : [0x78, 0x30])
            XCTAssertEqual(bytes.records.last?.header[0..<100], Data(repeating: 0x6E, count: 100))
            if length == 101 {
                XCTAssertEqual(try bytes.records[0].pax, ["path": Data(name.utf8)])
            }
            try TarTestSupport.verify(url, expected: [.init(name: name, data: Data([1]))])
        }
    }

    func testUstarPrefixBoundaryAvoidsUnnecessaryPax() throws {
        let directory = try ZipTestSupport.directory("tar-prefix")
        let url = directory.appendingPathComponent("archive.tar")
        let prefix = String(repeating: "p", count: 155)
        let leaf = String(repeating: "f", count: 100)
        let name = prefix + "/" + leaf
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(data: Data(), as: name, modificationDate: ZipTestSupport.date)
        try writer.addDirectory(prefix + "/" + String(repeating: "d", count: 99))
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.records.map(\.type), [0x30, 0x35])
        XCTAssertEqual(bytes.records[0].header[345..<500], Data(prefix.utf8))
        XCTAssertEqual(bytes.records[0].header[0..<100], Data(leaf.utf8))
        try TarTestSupport.verify(url, expected: [.init(name: name),
            .init(name: prefix + "/" + String(repeating: "d", count: 99) + "/", kind: .directory, permissions: 0o755, date: nil)])
    }

    func testJapanesePaxKeepsExactUTF8Bytes() throws {
        let directory = try ZipTestSupport.directory("tar-japanese")
        let url = directory.appendingPathComponent("archive.tar")
        let names = ["日本語/資料.txt", String(repeating: "凝縮", count: 20) + ".txt"]
        let data = Data("こんにちは\n".utf8)
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        for name in names {
            try writer.add(data: data, as: name, modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.records.map(\.type), [0x78, 0x30, 0x78, 0x30])
        XCTAssertEqual(try bytes.records[0].pax["path"], Data(names[0].utf8))
        XCTAssertEqual(try bytes.records[2].pax["path"], Data(names[1].utf8))
        try TarTestSupport.verify(url, expected: names.map { .init(name: $0, data: data) })
        // String の正規等価比較だけでは byte の変化を見逃すので、ツール出力を直接比較する。
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bsdtar-t.log")),
                       Data(names.map { $0 + "\n" }.joined().utf8))
    }

    func testDecomposedInputUsesSharedNFCNormalization() throws {
        let directory = try ZipTestSupport.directory("tar-nfc")
        let url = directory.appendingPathComponent("archive.tar")
        let name = "日本語/ガラス.txt"
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(data: Data(), as: name.decomposedStringWithCanonicalMapping, modificationDate: ZipTestSupport.date)
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(try bytes.records[0].pax["path"], Data(name.utf8))
        try TarTestSupport.verify(url, expected: [.init(name: name)])
        // Apple bsdtar の一覧は濁点を分解する。書庫内と KaitoKit の NFC byte とは区別する。
        let listed = try String(contentsOf: directory.appendingPathComponent("bsdtar-t.log"), encoding: .utf8)
        XCTAssertEqual(Data(listed.precomposedStringWithCanonicalMapping.utf8), Data((name + "\n").utf8))
    }

    func testOctalSizeOverflowUsesPaxAndBase256Header() throws {
        let directory = try ZipTestSupport.directory("tar-size-overflow")
        for size: UInt64 in [0o77777777777, 0o100000000000, UInt64.max] {
            let headers = TarRecords.Entry(name: Data("large".utf8), size: size).headers()
            let header = Data(headers.suffix(512))
            TarBytes.checksum(header)
            if size == 0o77777777777 {
                XCTAssertEqual(headers.count, 512)
                XCTAssertEqual(header[124..<136], Data("77777777777\0".utf8))
            } else {
                XCTAssertEqual(headers[156], 0x78)
                let length = try XCTUnwrap(Int(String(decoding: headers[124..<135], as: UTF8.self), radix: 8))
                let record = TarBytes.Record(offset: 0, header: Data(headers.prefix(512)), payload: headers.subdata(in: 512..<(512 + length)))
                XCTAssertEqual(try record.pax["size"], Data(String(size).utf8))
                let encoded = Data([0x80, 0, 0, 0]) + Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
                XCTAssertEqual(header[124..<136], encoded)
            }
        }
        // 8 GiB の payload は作らず、実際に書く header を Python の独立 parser に渡す。
        let url = directory.appendingPathComponent("header-only.tar")
        try TarRecords.Entry(name: Data("large".utf8), size: 8_589_934_592).headers().write(to: url)
        let script = "import tarfile,sys; t=tarfile.open(sys.argv[1]); m=t.next(); print(m.name,m.size,m.pax_headers['size']); t.close()"
        let output = try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-large-header")
        XCTAssertEqual(output, "large 8589934592 8589934592\n")
        ZipTestSupport.report("TAR SIZE OVERFLOW: 8 GiB header constructed directly; no 8 GiB payload was written")
    }

    func testOwnerNumericOverflowAndOwnerOptIn() throws {
        let headers = TarRecords.Entry(name: Data("owner".utf8), uid: 0o10000000, gid: UInt32.max).headers()
        let length = try XCTUnwrap(Int(String(decoding: headers[124..<135], as: UTF8.self), radix: 8))
        let record = TarBytes.Record(offset: 0, header: Data(headers.prefix(512)), payload: headers.subdata(in: 512..<(512 + length)))
        XCTAssertEqual(try record.pax, ["uid": Data("2097152".utf8), "gid": Data("4294967295".utf8)])
        let header = Data(headers.suffix(512))
        XCTAssertEqual(header[108..<116], Data([0x80, 0, 0, 0, 0, 0x20, 0, 0]))
        XCTAssertEqual(header[116..<124], Data([0x80, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]))
        TarBytes.checksum(header)
        let directory = try ZipTestSupport.directory("tar-owner-opt-in")
        let source = directory.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let url = directory.appendingPathComponent("archive.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar, options: WriterOptions(preserveOwnerIDs: true))
        try writer.add(contentsOf: source, as: "file")
        try writer.finish()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.entries[0].formatSpecific["uid"], (attributes[.ownerAccountID] as? NSNumber)?.stringValue)
        XCTAssertEqual(reader.entries[0].formatSpecific["gid"], (attributes[.groupOwnerAccountID] as? NSNumber)?.stringValue)
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertTrue(try XCTUnwrap(bytes.records.last).header[265..<329].allSatisfy { $0 == 0 })
    }

    func testDirectoriesSymlinksAndHardLinksRestoreTheirTypes() throws {
        let directory = try ZipTestSupport.directory("tar-tree")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let data = Data("linked content\n".utf8)
        let file = source.appendingPathComponent("a.txt")
        try data.write(to: file)
        try FileManager.default.linkItem(at: file, to: source.appendingPathComponent("b-hard"))
        let link = source.appendingPathComponent("c-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")
        for (url, mode) in [(source, 0o755), (source.appendingPathComponent("sub"), 0o750), (file, 0o640)] {
            try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date, .posixPermissions: mode], ofItemAtPath: url.path)
        }
        let url = directory.appendingPathComponent("archive.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(contentsOf: source, as: "tree")
        try writer.addDirectory("empty")
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.records.map(\.type), [0x35, 0x30, 0x31, 0x32, 0x35, 0x35])
        XCTAssertEqual(Data(bytes.records[2].header[157..<257].prefix { $0 != 0 }), Data("tree/a.txt".utf8))
        XCTAssertEqual(Data(bytes.records[3].header[157..<257].prefix { $0 != 0 }), Data("a.txt".utf8))
        try TarTestSupport.verify(url, expected: [
            .init(name: "tree/", kind: .directory, permissions: 0o755),
            .init(name: "tree/a.txt", data: data, permissions: 0o640),
            .init(name: "tree/b-hard", kind: .hardlink, permissions: 0o640, link: "tree/a.txt"),
            .init(name: "tree/c-link", kind: .symlink, permissions: 0o755, date: nil, link: "a.txt"),
            .init(name: "tree/sub/", kind: .directory, permissions: 0o750),
            .init(name: "empty/", kind: .directory, permissions: 0o755, date: nil)
        ])
    }

    func testLongSymlinkAndHardLinkTargetsUsePaxLinkpath() throws {
        let directory = try ZipTestSupport.directory("tar-long-links")
        let source = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("alias")
        let link = directory.appendingPathComponent("link")
        let target = String(repeating: "a", count: 101)
        let data = Data("long links".utf8)
        try data.write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date, .posixPermissions: 0o644], ofItemAtPath: source.path)
        let url = directory.appendingPathComponent("archive.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(contentsOf: source, as: target)
        try writer.add(contentsOf: alias, as: "hard")
        try writer.add(contentsOf: link, as: "sym")
        try writer.finish()
        let bytes = try TarBytes(Data(contentsOf: url))
        XCTAssertEqual(bytes.records.map(\.type), [0x78, 0x30, 0x78, 0x31, 0x78, 0x32])
        XCTAssertEqual(try bytes.records[2].pax["linkpath"], Data(target.utf8))
        XCTAssertEqual(try bytes.records[4].pax["linkpath"], Data(target.utf8))
        try TarTestSupport.verify(url, expected: [.init(name: target, data: data),
            .init(name: "hard", kind: .hardlink, link: target),
            .init(name: "sym", kind: .symlink, permissions: 0o755, date: nil, link: target)])
    }

    func testActualXattrIsNotArchivedOrRestored() throws {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let directory = try ZipTestSupport.directory("tar-metadata-\(format)")
            let source = directory.appendingPathComponent("source")
            let payload = Data("metadata-free payload\n".utf8)
            try payload.write(to: source)
            let key = "com.gyoshukukit.fixture"
            let value = "PRIVATE-XATTR-SENTINEL-4937"
            XCTAssertEqual(try ZipTestSupport.run("/usr/bin/xattr", ["-w", key, value, source.path], in: directory, log: "xattr-write"), "")
            XCTAssertEqual(try ZipTestSupport.run("/usr/bin/xattr", ["-p", key, source.path], in: directory, log: "xattr-read"), value + "\n")
            try FileManager.default.setAttributes([.modificationDate: ZipTestSupport.date, .posixPermissions: 0o644], ofItemAtPath: source.path)
            let url = directory.appendingPathComponent(format == .tar ? "archive.tar" : "archive.tar.gz")
            let writer = try ArchiveWriter.create(url: url, format: format)
            try writer.add(contentsOf: source, as: "file")
            try writer.finish()
            try TarTestSupport.verify(url, expected: [.init(name: "file", data: payload)], gzip: format == .tarGzip)
            let script = "import gzip,sys; b=gzip.open(sys.argv[1],'rb').read() if sys.argv[1].endswith('.gz') else open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(b); print(len(b))"
            let rawURL = directory.appendingPathComponent("raw.tar")
            let output = try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path, rawURL.path], in: directory, log: "python-raw")
            let raw = try Data(contentsOf: rawURL)
            XCTAssertEqual(output, "\(raw.count)\n")
            let bytes = try TarBytes(raw)
            XCTAssertEqual(bytes.records.map { String(decoding: $0.name, as: UTF8.self) }, ["file"])
            for marker in ["._", "SCHILY.xattr", key, value] { XCTAssertNil(raw.range(of: Data(marker.utf8))) }
            let restored = try ZipTestSupport.run("/usr/bin/xattr", ["-l", directory.appendingPathComponent("extracted/file").path], in: directory, log: "xattr-restored")
            XCTAssertFalse(restored.contains(key), restored)
            XCTAssertFalse(restored.contains(value), restored)
        }
    }

    func testMtimeTruncationNegativeAndOctalOverflow() throws {
        for (index, seconds) in [1_700_000_001.875, -1.25, 8_589_934_592.0].enumerated() {
            let directory = try ZipTestSupport.directory("tar-mtime-\(index)")
            let url = directory.appendingPathComponent("archive.tar")
            let writer = try ArchiveWriter.create(url: url, format: .tar)
            try writer.add(data: Data(), as: "dated", modificationDate: Date(timeIntervalSince1970: seconds))
            try writer.finish()
            let bytes = try TarBytes(Data(contentsOf: url))
            if index == 0 {
                XCTAssertEqual(bytes.records.map(\.type), [0x30])
                XCTAssertEqual(Int(String(decoding: bytes.records[0].header[136..<147], as: UTF8.self), radix: 8), 1_700_000_001)
            } else {
                XCTAssertEqual(bytes.records.map(\.type), [0x78, 0x30])
                XCTAssertEqual(try bytes.records[0].pax["mtime"], Data(String(Int64(floor(seconds))).utf8))
                XCTAssertNotEqual(bytes.records[1].header[136] & 0x80, 0)
            }
            try TarTestSupport.verify(url, expected: [.init(name: "dated", date: Date(timeIntervalSince1970: floor(seconds)))])
        }
        for seconds in [Double.nan, .infinity, -.infinity, -Double(Int64.min)] {
            XCTAssertThrowsError(try TarRecords.timestamp(Date(timeIntervalSince1970: seconds)))
        }
    }

    func testSharedPathValidationAndFailedOutputCleanup() throws {
        let directory = try ZipTestSupport.directory("tar-invalid")
        let paths = ["", "/absolute", "../escape", "a/../b", "a//b", "a\\b", "C:drive", "nul\0name", "file/", String(repeating: "界", count: 22_000)]
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            for (index, path) in paths.enumerated() {
                let url = directory.appendingPathComponent("\(format)-\(index)")
                let writer = try ArchiveWriter.create(url: url, format: format)
                try writer.add(data: Data([1]), as: "valid")
                XCTAssertThrowsError(try writer.add(data: Data(), as: path)) { XCTAssertEqual($0 as? WriterError, .invalidPath(path)) }
                XCTAssertThrowsError(try writer.finish())
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertThrowsError(try ArchiveReader.open(url: url))
            }
        }
    }

    func testDuplicateNamesAndFileDirectoryConflicts() throws {
        let directory = try ZipTestSupport.directory("tar-conflicts")
        for (index, names) in [["parent", "parent/child"], ["parent/child", "parent"], ["ガ", "カ\u{3099}"]].enumerated() {
            let url = directory.appendingPathComponent("\(index).tar")
            let writer = try ArchiveWriter.create(url: url, format: .tar)
            try writer.add(data: Data(), as: names[0])
            XCTAssertThrowsError(try writer.add(data: Data(), as: names[1]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testLifecycleExistingDestinationAndOutputAsSource() throws {
        let directory = try ZipTestSupport.directory("tar-lifecycle")
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let url = directory.appendingPathComponent("\(format).tar")
            do {
                let writer = try ArchiveWriter.create(url: url, format: format)
                try writer.add(data: Data([1]), as: "unfinished")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let writer = try ArchiveWriter.create(url: url, format: format)
            XCTAssertThrowsError(try writer.add(contentsOf: url, as: "self"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let finished = try ArchiveWriter.create(url: url, format: format)
            try finished.finish()
            let saved = try Data(contentsOf: url)
            try finished.finish()
            XCTAssertThrowsError(try finished.addDirectory("late"))
            XCTAssertThrowsError(try ArchiveWriter.create(url: url, format: format))
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    func testChangedHardLinkSourceFailsInsteadOfReferencingOldPayload() throws {
        let directory = try ZipTestSupport.directory("tar-changed-hardlink")
        let source = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("alias")
        try Data([1]).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        let url = directory.appendingPathComponent("archive.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(contentsOf: source, as: "first")
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data([2, 3]))
        try handle.close()
        XCTAssertThrowsError(try writer.add(contentsOf: alias, as: "second")) { XCTAssertEqual($0 as? WriterError, .sourceChanged("first")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanupDoesNotDeleteReplacedDestination() throws {
        let directory = try ZipTestSupport.directory("tar-replaced-output")
        let url = directory.appendingPathComponent("archive.tar")
        let moved = directory.appendingPathComponent("moved.tar")
        let writer = try ArchiveWriter.create(url: url, format: .tar)
        try writer.add(data: Data([1]), as: "file")
        try FileManager.default.moveItem(at: url, to: moved)
        let replacement = Data("someone else's file".utf8)
        try replacement.write(to: url)
        XCTAssertThrowsError(try writer.addDirectory("../invalid"))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try Data(contentsOf: moved).count, 0)
    }

    func testPublicTaskCancellationDuringPayloadRemovesOutput() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let directory = try ZipTestSupport.directory("tar-cancel-\(format)")
            let source = directory.appendingPathComponent("large-source")
            FileManager.default.createFile(atPath: source.path, contents: nil)
            let handle = try FileHandle(forWritingTo: source)
            // sparse fixture は直ちに取り消す。実際の出力が増えてから cancel する。
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
            defer { try? FileManager.default.removeItem(at: source) }
            let url = directory.appendingPathComponent(format == .tar ? "archive.tar" : "archive.tar.gz")
            let task = Task.detached {
                let writer = try ArchiveWriter.create(url: url, format: format, options: WriterOptions(deflateLevel: 0))
                try writer.add(contentsOf: source, as: "large")
                try writer.finish()
            }
            var observedPayload = false
            for _ in 0..<10_000 {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes?[.size] as? NSNumber, size.intValue > 1024 * 1024 {
                    observedPayload = true
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            task.cancel()
            XCTAssertTrue(observedPayload, "cancellation must occur after payload bytes are written")
            do { try await task.value; XCTFail("cancelled write succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertThrowsError(try ArchiveReader.open(url: url))
        }
    }

    func testCancellationBeforeFinishRemovesPreviouslyWrittenMembers() async throws {
        let directory = try ZipTestSupport.directory("tar-cancel-finish")
        let url = directory.appendingPathComponent("archive.tar")
        let task = Task {
            let writer = try ArchiveWriter.create(url: url, format: .tar)
            try writer.add(data: Data([1, 2, 3]), as: "complete-member")
            withUnsafeCurrentTask { $0?.cancel() }
            try writer.finish()
        }
        do { try await task.value; XCTFail("cancelled finish succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
