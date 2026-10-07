import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipAdditionalCompressionWriterTests: XCTestCase {
    private func roundTrip(encryption: ZipEncryption?) throws {
        let text = Data(repeating: 0x61, count: 1024 * 1024)
        let random = TestCorpus.random(8 * 1024 * 1024)
        for method in ZipAdditionalCompressionSupport.methods {
            let directory = try TestSupport.directory("zip-additional-\(method)-\(String(describing: encryption))")
            let archive = directory.appendingPathComponent("archive.zip")
            let password = encryption.map { _ in ZipAdditionalCompressionSupport.password }
            let options = WriterOptions(compressionMethod: method, password: password,
                                        zipEncryption: encryption ?? .aes256, compressionThreads: 2)
            let writer = try ArchiveWriter.create(url: archive, options: options)
            let files: [ExpectedEntry] = [
                .init(name: "one.txt", data: Data([0x41])),
                .init(name: "日本語/本文.txt", data: text),
                .init(name: "random.bin", data: random),
                .init(name: "zero"), .init(name: "photo.PNG", data: Data(text.prefix(1024)))
            ]
            for file in files { try writer.add(data: file.data, as: file.name, modificationDate: TestSupport.date) }
            try writer.add([.init(path: "folder", source: .directory(modificationDate: TestSupport.date))], events: nil)
            let link = directory.appendingPathComponent("disk-link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "one.txt")
            try writer.add(contentsOf: link, as: "link")
            try writer.finishAdditions(progress: { _ in })
            try writer.finish()
            let expected = files + [
                .init(name: "folder/", kind: .directory, permissions: 0o755),
                .init(name: "link", data: Data("one.txt".utf8), kind: .symlink, permissions: 0o755, date: nil)
            ]
            let bytes = ZipBytes(data: try Data(contentsOf: archive))
            let central = try ZipAdditionalCompressionSupport.centralRecords(archive)
            for (record, file) in zip(central, expected) {
                let cd = ZipBytes(data: record)
                let offset = Int(cd.u32(42))
                let compressed = file.kind == .file && !file.data.isEmpty && !file.name.hasSuffix(".PNG")
                let actualMethod: UInt16 = compressed ? method.rawValue : 0
                let encrypted = password != nil && file.kind == .file
                let headerMethod: UInt16 = encrypted && encryption == .aes256 ? 99 : actualMethod
                let version: UInt16 = encrypted && encryption == .aes256 ? 51 : actualMethod == 12 ? 46 : 20
                XCTAssertEqual(bytes.u16(offset + 8), headerMethod, file.name)
                XCTAssertEqual(cd.u16(10), headerMethod, file.name)
                XCTAssertEqual(bytes.u16(offset + 4), version, file.name)
                XCTAssertEqual(cd.u16(6), version, file.name)
                XCTAssertEqual(bytes.u16(offset + 6) & 8, 0, "data descriptor: \(file.name)")
                if encrypted && encryption == .aes256 {
                    let localAES = try XCTUnwrap(bytes.extras(offset, local: true)[0x9901])
                    let centralAES = try XCTUnwrap(cd.extras(0, local: false)[0x9901])
                    XCTAssertEqual(localAES, centralAES)
                    XCTAssertEqual(ZipBytes(data: localAES).u16(5), actualMethod)
                    XCTAssertEqual(localAES[4], 3)
                } else {
                    XCTAssertEqual(cd.u32(16), CRC32.checksum(file.data), file.name)
                    XCTAssertEqual(cd.u32(16), bytes.u32(offset + 14), file.name)
                }
            }
            try ZipAdditionalCompressionSupport.verify(archive, expected: expected, method: method,
                                                       password: password, aes: encryption == .aes256)
        }
    }

    func testPlainRoundTripsAndSevenZipOracle() throws { try roundTrip(encryption: nil) }
    func testAES256RoundTripsAndSevenZipOracle() throws { try roundTrip(encryption: .aes256) }
    func testZipCryptoRoundTripsAndSevenZipOracle() throws { try roundTrip(encryption: .zipCrypto) }

    func testEmptyArchives() throws {
        for method in ZipAdditionalCompressionSupport.methods {
            let directory = try TestSupport.directory("zip-additional-empty-\(method)")
            let archive = directory.appendingPathComponent("empty.zip")
            try ArchiveWriter.create(url: archive, options: .init(compressionMethod: method)).finish()
            try ZipAdditionalCompressionSupport.verify(archive, expected: [], method: method)
        }
    }

    func testBatchDiskInputsAndHeuristicOptOut() throws {
        let payload = Data(repeating: 0x42, count: 1024 * 1024)
        for method in ZipAdditionalCompressionSupport.methods {
            let directory = try TestSupport.directory("zip-additional-batch-\(method)")
            let disk = directory.appendingPathComponent("input")
            try payload.write(to: disk)
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date, .posixPermissions: 0o644], ofItemAtPath: disk.path)
            let archive = directory.appendingPathComponent("batch.zip")
            let writer = try ArchiveWriter.create(url: archive, options: .init(compressionMethod: method, useCompressionHeuristic: false, compressionThreads: 3))
            try writer.add([.init(path: "first.bin", source: .contents(of: disk)), .init(path: "second.png", source: .contents(of: disk))], events: nil)
            try writer.finish()
            try ZipAdditionalCompressionSupport.verify(archive, expected: [
                .init(name: "first.bin", data: payload), .init(name: "second.png", data: payload)
            ], method: method)
        }
    }

    func testBzip2LevelAndExactlyOneStream() throws {
        let payload = TestCorpus.random(8 * 1024 * 1024)
        for level in [1, 9] {
            let directory = try TestSupport.directory("zip-additional-single-bzip2-\(level)")
            let archive = directory.appendingPathComponent("archive.zip")
            let writer = try ArchiveWriter.create(url: archive, options: .init(compressionMethod: .bzip2, bzip2Level: level))
            try writer.add(data: payload, as: "payload.bin")
            try writer.finish()
            let bytes = ZipBytes(data: try Data(contentsOf: archive))
            let start = 30 + Int(bytes.u16(26)) + Int(bytes.u16(28))
            let compressed = bytes.data.subdata(in: start..<(start + Int(bytes.u32(18))))
            XCTAssertEqual(compressed.prefix(4), Data([0x42, 0x5a, 0x68, UInt8(48 + level)]))
            let stream = directory.appendingPathComponent("payload.bz2")
            try compressed.write(to: stream)
            // BZ2Decompressor は最初の stream の後ろを unused_data に残すので、連結を独立に検出できる。
            try TestSupport.run(ReferenceTool.python3, ["-c", "import bz2,sys; d=bz2.BZ2Decompressor(); out=d.decompress(open(sys.argv[1],'rb').read()); assert d.eof and not d.unused_data; open(sys.argv[2],'wb').write(out)", stream.path, directory.appendingPathComponent("decoded").path], in: directory, log: "single-stream")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("decoded")), payload)
        }
    }

    func testXZMultipleBlocksRemainOneStreamAcrossThreadCounts() throws {
        let payload = Data(repeating: 0x63, count: 33 * 1024 * 1024)
        var previous: Data?
        for threads in [1, 2] {
            let directory = try TestSupport.directory("zip-additional-xz-blocks-\(threads)")
            let archive = directory.appendingPathComponent("archive.zip")
            let writer = try ArchiveWriter.create(url: archive, options: .init(compressionMethod: .xz, compressionThreads: threads))
            try writer.add(data: payload, as: "large.txt", modificationDate: TestSupport.date)
            try writer.finish()
            let bytes = ZipBytes(data: try Data(contentsOf: archive))
            if let previous { XCTAssertEqual(bytes.data, previous) }
            previous = bytes.data
            let start = 30 + Int(bytes.u16(26)) + Int(bytes.u16(28))
            let compressed = bytes.data.subdata(in: start..<(start + Int(bytes.u32(18))))
            XCTAssertEqual(compressed.prefix(6), Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]))
            XCTAssertEqual(compressed.suffix(2), Data([0x59, 0x5a]))
            let indexSize = (Int(ZipBytes(data: compressed).u32(compressed.count - 8)) + 1) * 4
            let indexStart = compressed.count - 12 - indexSize
            XCTAssertEqual(compressed[indexStart], 0)
            XCTAssertEqual(compressed[indexStart + 1], 3)
            let stream = directory.appendingPathComponent("payload.xz")
            try compressed.write(to: stream)
            try TestSupport.run(ReferenceTool.python3, ["-c", "import lzma,sys; d=lzma.LZMADecompressor(); out=d.decompress(open(sys.argv[1],'rb').read()); assert d.eof and not d.unused_data; open(sys.argv[2],'wb').write(out)", stream.path, directory.appendingPathComponent("decoded").path], in: directory, log: "single-stream")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("decoded")), payload)
            try ZipAdditionalCompressionSupport.verify(archive, expected: [.init(name: "large.txt", data: payload)], method: .xz)
            if testRun?.failureCount == 0 {
                try FileManager.default.removeItem(at: directory.appendingPathComponent("decoded"))
                try FileManager.default.removeItem(at: directory.appendingPathComponent("extracted"))
            }
        }
    }

    func testSevenZipCreatedArchivesReadByKaitoKit() throws {
        let payloads: [(String, Data)] = [("one.txt", Data([0x41])), ("日本語.txt", Data(repeating: 0x61, count: 1024 * 1024)), ("random.bin", TestCorpus.random(8 * 1024 * 1024))]
        for method in ZipAdditionalCompressionSupport.methods {
            let directory = try TestSupport.directory("zip-additional-reverse-\(method)")
            for (name, data) in payloads { try data.write(to: directory.appendingPathComponent(name)) }
            let archive = directory.appendingPathComponent("7zip.zip")
            try ReferenceTool.run(ReferenceTool.sevenZip, ["a", "-tzip", "-mm=\(method == .bzip2 ? "BZip2" : "XZ")", archive.path] + payloads.map(\.0), in: directory, log: "7zz-a", workingDirectory: directory)
            let records = try ZipAdditionalCompressionSupport.centralRecords(archive)
            for record in records {
                let cd = ZipBytes(data: record)
                let name = String(decoding: record.subdata(in: 46..<(46 + Int(cd.u16(28)))), as: UTF8.self)
                // 7-Zip は膨らむ1 byte・randomを stored に戻す。圧縮できる本文で指定方式を必ず検査する。
                if name == "日本語.txt" { XCTAssertEqual(cd.u16(10), method.rawValue) }
                else { XCTAssertTrue([0, method.rawValue].contains(cd.u16(10))) }
            }
            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(Set(reader.entries.map(\.name)), Set(payloads.map(\.0)))
            for entry in reader.entries { XCTAssertEqual(try reader.read(entry), try XCTUnwrap(payloads.first { $0.0 == entry.name }).1, entry.name) }
        }
    }

    func testPendingInputBoundsValidationAndZIP64Reservation() throws {
        for method in ZipAdditionalCompressionSupport.methods {
            for threads in [1, 2, 64] {
                for encryption in [ZipEncryption.aes256, .zipCrypto] {
                    let options = WriterOptions(compressionMethod: method, password: "password", zipEncryption: encryption, compressionThreads: threads)
                    XCTAssertNoThrow(try options.validate(for: .zip))
                    let expected: UInt64 = method == .bzip2
                        ? (threads == 1 ? 0 : threads == 2 ? 32 << 20 : 256 << 20)
                        : (threads == 1 ? 32 << 20 : threads == 2 ? 48 << 20 : 1040 << 20)
                    XCTAssertEqual(options.maximumPendingInputBytes(for: .zip, physicalMemory: 8 << 30), expected)
                }
            }
            for level in [0, 10] { XCTAssertThrowsError(try WriterOptions(compressionMethod: method, bzip2Level: level).validate(for: .zip)) }
            XCTAssertThrowsError(try WriterOptions(compressionMethod: method, compressionThreads: 65).validate(for: .zip))
            let directory = try TestSupport.directory("zip-additional-bound-\(method)")
            let archive = directory.appendingPathComponent("unused")
            FileManager.default.createFile(atPath: archive.path, contents: nil)
            let handle = try FileHandle(forWritingTo: archive)
            defer { try? handle.close() }
            let writer = ZipWriter(output: handle, url: archive, options: .init(compressionMethod: method), deflateBlockSize: DeflateBlock.size,
                                   deflateEncoder: DeflateBlock.encode, salt: { Data(repeating: 0, count: 16) })
            let entry = try writer.makeEntry(name: "large", mode: FileMode.regular | 0o644, size: UInt64(UInt32.max) - 1,
                                             date: TestSupport.date, atime: nil, owners: nil)
            XCTAssertTrue(entry.reservedZIP64)
            let originalLength = entry.local().count
            var final = entry
            final.compressedSize = UInt64(UInt32.max) + 1
            XCTAssertEqual(final.local().count, originalLength)
            XCTAssertEqual(ZipBytes(data: final.local()).u16(4), method == .bzip2 ? 46 : 45)
        }
        XCTAssertEqual(WriterOptions().compressionMethod, .deflate)
    }
}
