import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterSourceProbeTests: XCTestCase {
    private let memberName = "member.bin"
    private let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .sevenZip, .lha, .tar, .tarGzip, .tarBzip2, .tarXZ]

    private func suffix(_ format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .lha: "lzh"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXZ: "tar.xz"
        }
    }

    private func fixture(_ bytes: Data, extension suffix: String) throws -> URL {
        let directory = try ZipTestSupport.directory("source-probe-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.\(suffix)")
        try bytes.write(to: url)
        return url
    }

    private func lha(_ payload: Data, level: UInt8 = 2, method: String = "-lh0-", os: UInt8 = 0x6D) -> Data {
        let filename = Data(memberName.utf8)
        var header = Data(count: 2)
        header.append(contentsOf: method.utf8)
        header.le(UInt32(payload.count))
        header.le(UInt32(payload.count))
        header.le(level == 2 ? UInt32(1_700_000_000) : UInt32(0x576EB1AA))
        header.append(contentsOf: [0x20, level])
        if level != 2 {
            header.append(UInt8(filename.count))
            header.append(filename)
        }
        header.le(LHATestSupport.crc(payload))
        header.append(os)
        if level == 2 {
            header.le(UInt16(filename.count + 3))
            header.append(1)
            header.append(filename)
        }
        if level != 0 { header.le(UInt16(0)) }
        if level == 2 {
            header.zipSet(UInt16(header.count), at: 0)
        } else {
            header[0] = UInt8(header.count - 2)
            header[1] = header.dropFirst(2).reduce(UInt8(0), &+)
        }
        return header + payload + Data([0])
    }

    private func macBinary(dataFork: Data, resourceFork: Data) -> Data {
        var result = Data(count: 128)
        result[1] = UInt8(memberName.utf8.count)
        result.replaceSubrange(2..<(2 + memberName.utf8.count), with: memberName.utf8)
        result.replaceSubrange(65..<73, with: "BINATEST".utf8)
        for (offset, count) in [(83, dataFork.count), (87, resourceFork.count)] {
            for byte in 0..<4 { result[offset + byte] = UInt8(truncatingIfNeeded: count >> (24 - byte * 8)) }
        }
        for fork in [dataFork, resourceFork] {
            result.append(fork)
            result.append(Data(count: (128 - fork.count % 128) % 128))
        }
        return result
    }

    private func assertRefused(_ url: URL, reason: String, entriesAccepted: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: url)
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(appleDoublePolicy: .expose))
        let output = url.deletingLastPathComponent().appendingPathComponent("output")
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        for format in formats {
            if entriesAccepted {
                XCTAssertNoThrow(try ArchiveRewriter.probe(entries: reader.entries, format: format), file: file, line: line)
            } else {
                XCTAssertThrowsError(try ArchiveRewriter.probe(entries: reader.entries, format: format), file: file, line: line) {
                    XCTAssertEqual($0 as? RewriterError, .unrepresentable(entry: self.memberName, reason: reason),
                                   file: file, line: line)
                }
            }
            XCTAssertThrowsError(try ArchiveRewriter.probe(reader: reader, format: format), file: file, line: line) {
                XCTAssertEqual($0 as? RewriterError, .unrepresentable(entry: self.memberName, reason: reason), file: file, line: line)
            }
            for destination in [nil, output] {
                XCTAssertThrowsError(try ArchiveRewriter.open(url: url, output: destination, format: format), file: file, line: line) {
                    XCTAssertEqual($0 as? RewriterError, .unrepresentable(entry: self.memberName, reason: reason), file: file, line: line)
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), files,
                       file: file, line: line)
    }

    func testMacBinaryEnvelopeRefusedWithAndWithoutResourceFork() throws {
        for level: UInt8 in [1, 2] {
            for forks in [(Data("data fork".utf8), Data("resource fork".utf8)),
                          (Data("data only".utf8), Data()), (Data(), Data("resource only".utf8))] {
                let envelope = macBinary(dataFork: forks.0, resourceFork: forks.1)
                let url = try fixture(lha(envelope, level: level), extension: "lzh")
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(reader.entries[0].formatSpecific["osID"], "m")
                XCTAssertEqual(reader.entries[0].uncompressedSize, UInt64(envelope.count))
                XCTAssertEqual(try reader.stream(reader.entries[0]).remaining, UInt64(forks.0.count))
                XCTAssertEqual(try reader.read(reader.entries[0]), forks.0)
                try assertRefused(url,
                    reason: "MacBinary の envelope・resource fork を保持できないため再圧縮できません",
                    entriesAccepted: true)
            }
        }
    }

    func testPlainMacLHAAndUnfilteredEnvelopesRemainEditable() throws {
        let plain = Data(repeating: 0x5A, count: 300)
        let envelope = macBinary(dataFork: Data("data".utf8), resourceFork: Data("resource".utf8))
        for (payload, level, os): (Data, UInt8, UInt8) in [
            (plain, 1, 0x6D), (plain, 2, 0x6D), (Data(), 2, 0x6D),
            (envelope, 0, 0x6D), (envelope, 2, 0x55)
        ] {
            let url = try fixture(lha(payload, level: level, os: os), extension: "lzh")
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(appleDoublePolicy: .expose))
            let activeStream = try reader.stream(reader.entries[0])
            for format in formats {
                try ArchiveRewriter.probe(reader: reader, format: format)
                try ArchiveRewriter.probe(entries: reader.entries, format: format)
                let output = url.deletingLastPathComponent().appendingPathComponent("output.\(suffix(format))")
                let rewriter = try ArchiveRewriter.open(url: url, output: output, format: format)
                try rewriter.commit()
                let rewritten = try ArchiveReader.open(url: output)
                XCTAssertEqual(try rewritten.read(rewritten.entries[0]), payload)
            }
            XCTAssertEqual(try activeStream.readAll(), payload)
        }
    }

    func testUnsupportedLHAMethodsRefusedFromPublicMetadata() throws {
        for method in ["-pm2-", "-lh9-"] {
            for os: UInt8 in [0x55, 0x6D] {
                let url = try fixture(lha(Data("payload".utf8), method: method, os: os), extension: "lzh")
                let reader = try ArchiveReader.open(url: url)
                XCTAssertThrowsError(try reader.stream(reader.entries[0])) {
                    XCTAssertEqual($0 as? KaitoError, .unsupportedMethod(method))
                }
                try assertRefused(url, reason: "未対応の LHA 圧縮方式は再圧縮できません: \(method)")
            }
        }
    }

    func testEntriesOnlyStillRefusesMacLHANameCollisions() throws {
        for level: UInt8 in [1, 2] {
            let member = lha(Data("plain contents".utf8), level: level)
            let url = try fixture(Data(member.dropLast()) + member, extension: "lzh")
            try assertRefused(url, reason: "正規化した出力名が他の entry と衝突しています: \(memberName)")
        }
    }

    private func sevenZip(method: UInt8, chained: Bool = false) -> Data {
        let payload = Data("contents".utf8)
        var header = Data([1, 4, 6, 0, 1, 9, UInt8(payload.count), 0, 7, 11, 1, 0])
        header.append(contentsOf: chained ? [2, 1, 0, 1, method, 1, 0] : [1, 1, method])
        header.append(12)
        if chained { header.append(UInt8(payload.count)) }
        header.append(contentsOf: [UInt8(payload.count), 0, 0, 5, 1, 17, UInt8(1 + (memberName.utf16.count + 1) * 2), 0])
        for unit in memberName.utf16 { header.le(unit) }
        header.append(contentsOf: [0, 0, 0, 0])
        var start = Data()
        start.le(UInt64(payload.count))
        start.le(UInt64(header.count))
        start.le(CRC32.checksum(header))
        var result = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
        result.le(CRC32.checksum(start))
        return result + start + payload + header
    }

    func testUnsupportedSevenZipCoderRefusedIncludingCoderChains() throws {
        for chained in [false, true] {
            let url = try fixture(sevenZip(method: 0xFE, chained: chained), extension: "7z")
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.entries[0].methodDescription, chained ? "Copy+7z method 0xFE" : "7z method 0xFE")
            XCTAssertThrowsError(try reader.stream(reader.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("7z method 0xFE"))
            }
            try assertRefused(url, reason: "未対応の 7z 圧縮方式は再圧縮できません: 7z method 0xFE")
        }
        let url = try fixture(sevenZip(method: 0), extension: "7z")
        let reader = try ArchiveReader.open(url: url)
        for format in formats {
            try ArchiveRewriter.probe(entries: reader.entries, format: format)
            try ArchiveRewriter.probe(reader: reader, format: format)
            let output = url.deletingLastPathComponent().appendingPathComponent("output.\(suffix(format))")
            let rewriter = try ArchiveRewriter.open(url: url, output: output, format: format)
            try rewriter.commit()
            let rewritten = try ArchiveReader.open(url: output)
            XCTAssertEqual(try rewritten.read(rewritten.entries[0]), Data("contents".utf8))
        }
    }
}
