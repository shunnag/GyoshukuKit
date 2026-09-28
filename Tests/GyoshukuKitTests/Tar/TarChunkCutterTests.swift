import Foundation
import Darwin
import KaitoKit
import XCTest
import zlib
@testable import GyoshukuKit

enum TarChunkCutterTestSupport {
    typealias Member = (groupStart: Int, dataStart: Int, end: Int)

    static func members(in raw: Data) throws -> [Member] {
        let tar = try TarBytes(raw)
        var result: [Member] = []
        var start = 0
        for record in tar.records where record.type != 0x78 {
            let end = record.offset + 512 + (record.payload.count + 511) / 512 * 512
            result.append((start, record.offset + 512, end))
            start = end
        }
        return result
    }

    static func ranges(members: [Member], total: Int, limit: Int) -> [Range<Int>] {
        ranges(members: members, total: total, limits: .init(uniform: limit))
    }

    // 実装の状態機械を使わず、member の範囲から境界を求める。
    static func ranges(members: [Member], total: Int, limits: TarChunkLimits) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        func cut(_ end: Int) {
            if end > start { result.append(start..<end); start = end }
        }
        for member in members {
            if member.end - start <= limits.packing { continue }
            cut(member.groupStart)
            if member.end - start > limits.packing {
                for end in [member.dataStart, member.end] {
                    while end - start > limits.piece { cut(start + limits.piece) }
                    cut(end)
                }
            }
        }
        cut(members.last?.end ?? 0)
        cut(total)
        return result
    }

    static func expectedLengths(_ url: URL, format: GyoshukuKit.ArchiveFormat, limit: Int) throws -> [Int] {
        try expectedLengths(url, format: format, limits: .init(uniform: limit))
    }

    static func expectedLengths(_ url: URL, format: GyoshukuKit.ArchiveFormat, limits: TarChunkLimits) throws -> [Int] {
        let decoded = try decode(url, format: format)
        return ranges(members: try members(in: decoded.raw), total: decoded.raw.count, limits: limits).map(\.count)
    }

    static func decode(_ url: URL, format: GyoshukuKit.ArchiveFormat) throws -> (raw: Data, lengths: [Int]) {
        if format == .tarGzip { return try gzip(Data(contentsOf: url)) }
        let rawURL = url.appendingPathExtension("decoded")
        let script = """
        import sys,bz2,lzma,struct,json,zlib
        b=open(sys.argv[1],'rb').read(); sizes=[]
        if sys.argv[3]=='bz':
            parts=[]
            while b:
                d=bz2.BZ2Decompressor(); part=d.decompress(b); assert d.eof
                parts.append(part); sizes.append(len(part)); b=d.unused_data
            raw=b''.join(parts)
        else:
            raw=lzma.decompress(b)
            n=(struct.unpack('<I',b[-8:-4])[0]+1)*4
            idx=b[-12-n:-12]; assert idx[0]==0
            assert zlib.crc32(idx[:-4])==struct.unpack('<I',idx[-4:])[0]
            pos=1
            def vli():
                global pos
                value=shift=0
                while True:
                    x=idx[pos]; pos+=1; value|=(x&127)<<shift
                    if x<128: return value
                    shift+=7
            count=vli()
            for _ in range(count):
                vli(); sizes.append(vli())
            assert sum(sizes)==len(raw)
        open(sys.argv[2],'wb').write(raw)
        print(json.dumps(sizes))
        """
        let output = try TestSupport.run(ReferenceTool.python3,
            ["-c", script, url.path, rawURL.path, format == .tarBzip2 ? "bz" : "xz"],
            in: url.deletingLastPathComponent(), log: url.lastPathComponent + "-decode")
        let lengths = try JSONDecoder().decode([Int].self, from: Data(output.utf8))
        return (try Data(contentsOf: rawURL), lengths)
    }

    private static func gzip(_ data: Data) throws -> (raw: Data, lengths: [Int]) {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }
        var raw = Data(), ends: [Int] = []
        var previousIn = 0, previousOut = 0
        try data.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(source.count)
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_BLOCK)
                }
                raw.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { break }
                guard status == Z_OK else { throw CocoaError(.fileReadCorruptFile) }
                if stream.data_type & 128 != 0 {
                    let consumed = Int(stream.total_in), produced = Int(stream.total_out)
                    if stream.data_type & 7 == 0, consumed >= 4,
                       data[(consumed - 4)..<consumed] == Data([0, 0, 255, 255]),
                       produced == previousOut, (4...5).contains(consumed - previousIn) {
                        ends.append(produced)
                    }
                    previousIn = consumed
                    previousOut = produced
                }
            }
            XCTAssertEqual(stream.avail_in, 0)
        }
        ends.append(raw.count)
        var start = 0
        return (raw, ends.map { end in defer { start = end }; return end - start })
    }
}

final class TarChunkCutterTests: XCTestCase {
    private struct Item {
        let name: String
        let data: Data
        var mode: UInt16 = 0o100644
    }
    private let formats: [GyoshukuKit.ArchiveFormat] = [.tarGzip, .tarBzip2, .tarXZ]

    private func limits(_ format: GyoshukuKit.ArchiveFormat) -> TarChunkLimits {
        switch format {
        case .tarGzip: .init(uniform: 8192)
        case .tarBzip2: .init(uniform: 500_000)
        default: .init(packing: 65_536, piece: 262_144)
        }
    }

    private func items(limits: TarChunkLimits) -> [Item] {
        let limit = limits.packing
        let lengths = [1, limit - 512, limit - 511, 2 * limit - 512, 5 * limit / 2 - 512,
                       limit / 2, limit / 2, 0, limit + 1, 3 * limit,
                       limits.piece - 512, limits.piece - 511, 2 * limits.piece + 7]
        let seed = LHATestSupport.random(8192)
        var result = lengths.enumerated().map { index, size in
            var data = Data()
            while data.count < size { data.append(seed) }
            return Item(name: "file-\(index)", data: Data(data.prefix(size)))
        }
        result += [.init(name: "directory/", data: Data(), mode: 0o40755),
                   .init(name: "link", data: Data("file-0".utf8), mode: 0o120755),
                   .init(name: String(repeating: "n", count: 201), data: seed),
                   .init(name: String(repeating: "p", count: min(limit + 53, 65_000)), data: Data([7]))]
        return result
    }

    private func write(_ items: [Item], to url: URL, format: GyoshukuKit.ArchiveFormat,
                       threads: Int = 4, shortReads: Bool = false) throws {
        let writer = try ArchiveWriter.create(url: url, format: format,
            options: WriterOptions(bzip2Level: 1, compressionThreads: threads),
            deflateBlockSize: 8192, lzmaChunkSize: 262_144, xzPackingSize: 65_536)
        for item in items {
            var offset = 0
            try writer.addEntry(path: item.name, mode: item.mode, size: UInt64(item.data.count),
                                date: TestSupport.date, atime: nil, owners: nil) { requested in
                let count = min(requested, shortReads ? 997 : requested, item.data.count - offset)
                defer { offset += count }
                return item.data.subdata(in: offset..<(offset + count))
            }
        }
        try writer.finish()
    }

    private func verifyLayout(_ url: URL, format: GyoshukuKit.ArchiveFormat, limit: Int) throws -> Data {
        try verifyLayout(url, format: format, limits: .init(uniform: limit))
    }

    private func verifyLayout(_ url: URL, format: GyoshukuKit.ArchiveFormat, limits: TarChunkLimits) throws -> Data {
        let decoded = try TarChunkCutterTestSupport.decode(url, format: format)
        let members = try TarChunkCutterTestSupport.members(in: decoded.raw)
        let expected = TarChunkCutterTestSupport.ranges(members: members, total: decoded.raw.count, limits: limits)
        XCTAssertEqual(decoded.lengths, expected.map(\.count))
        XCTAssertTrue(expected.dropLast().allSatisfy { $0.count <= limits.piece })
        let eof = members.last?.end ?? 0
        XCTAssertEqual(expected.last, eof..<decoded.raw.count)
        XCTAssertEqual(decoded.lengths.last, 1024 + (10_240 - (eof + 1024) % 10_240) % 10_240)
        XCTAssertTrue(decoded.raw[eof...].allSatisfy { $0 == 0 })
        return decoded.raw
    }

    func testMemberBoundariesEOFThreadCountsAndShortReads() throws {
        let directory = try TestSupport.directory("tar-chunk-layout")
        for format in formats {
            let items = items(limits: limits(format))
            let plain = directory.appendingPathComponent("\(format).tar")
            try write(items, to: plain, format: .tar)
            let raw = try Data(contentsOf: plain)
            var expected: Data?
            for threads in [1, 2, 4, 8] {
                for short in [false, true] {
                    let url = directory.appendingPathComponent("\(format)-\(threads)-\(short)")
                    try write(items, to: url, format: format, threads: threads, shortReads: short)
                    XCTAssertEqual(try verifyLayout(url, format: format, limits: limits(format)), raw)
                    let bytes = try Data(contentsOf: url)
                    if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
                }
            }
        }
    }

    func testEmptyArchiveHasOneFinalChunkEvenWithSmallLimit() throws {
        let directory = try TestSupport.directory("tar-chunk-empty")
        for format in formats {
            let url = directory.appendingPathComponent("\(format)")
            try write([], to: url, format: format)
            XCTAssertEqual(try verifyLayout(url, format: format, limits: limits(format)), Data(count: 10_240))
        }
    }

    func testExactUnpaddedHintLengthsAndRollingGzipDictionary() throws {
        let directory = try TestSupport.directory("tar-chunk-hints")
        for format in formats {
            let size = limits(format).packing
            let lengths = [(511, size - 511), (512, size - 511), (513, 2 * size - 513),
                           (size + 1, 7), (512, 5 * size / 2 - 512), (512, 0)]
            var raw = Data(), members: [TarChunkCutterTestSupport.Member] = []
            for (header, body) in lengths {
                let start = raw.count
                let seed = LHATestSupport.random(4096)
                var data = Data()
                while data.count < header + body { data.append(seed) }
                raw.append(data.prefix(header + body))
                members.append((start, start + header, raw.count))
            }
            let eof = raw.count
            raw.append(Data(count: 10_240))
            let ranges = TarChunkCutterTestSupport.ranges(members: members, total: raw.count, limits: limits(format))
            let compressor = try compressor(format, small: true)
            var actual = Data()
            for member in members {
                compressor.beginMember(headerLength: UInt64(member.dataStart - member.groupStart),
                                       bodyLength: UInt64(member.end - member.dataStart))
                try compressor.write(raw[member.groupStart..<member.end], finish: false) { actual.append($0) }
            }
            compressor.beginEndOfArchive()
            try compressor.write(raw[eof...], finish: true) { actual.append($0) }
            let url = directory.appendingPathComponent("\(format)")
            try actual.write(to: url)
            let decoded = try TarChunkCutterTestSupport.decode(url, format: format)
            XCTAssertEqual(decoded.raw, raw)
            XCTAssertEqual(decoded.lengths, ranges.map(\.count))
            if format == .tarGzip {
                XCTAssertEqual(actual, try serial(raw, ranges: ranges, format: format, rollingDictionary: true))
            }
        }
    }

    func testUnhintedOutputMatchesOriginalFixedWidthFraming() throws {
        for format in formats {
            let size: Int = switch format {
            case .tarGzip: DeflateBlock.size
            case .tarBzip2: ParallelBzip2Compressor.chunkSize(level: 9)
            default: ParallelXZCompressor.defaultBlockSize
            }
            let seed = LHATestSupport.random(8192)
            var raw = Data()
            while raw.count < size + 137 { raw.append(seed) }
            raw = Data(raw.prefix(size + 137))
            let ranges = [0..<size, size..<raw.count]
            let expected = try serial(raw, ranges: ranges, format: format, rollingDictionary: false)
            let compressor = try compressor(format, small: false)
            var actual = Data()
            for offset in stride(from: 0, to: raw.count, by: 997) {
                try compressor.write(raw[offset..<min(offset + 997, raw.count)], finish: false) { actual.append($0) }
            }
            try compressor.write(Data(), finish: true) { actual.append($0) }
            XCTAssertEqual(actual, expected)
        }
    }

    func testRewriterUsesMemberLayoutForAllCompressedTarFormats() throws {
        let directory = try TestSupport.directory("tar-chunk-rewriter")
        let items = [Item(name: "large", data: Data(repeating: 65, count: 17 * 1024 * 1024)),
                     Item(name: "small", data: Data([1, 2, 3])), Item(name: "empty", data: Data())]
        let source = directory.appendingPathComponent("source.tar")
        try write(items, to: source, format: .tar)
        for format in formats {
            let suffix = format == .tarGzip ? "gz" : (format == .tarBzip2 ? "bz2" : "xz")
            let url = directory.appendingPathComponent("archive.tar.\(suffix)")
            try ArchiveRewriter.open(url: source, output: url, format: format,
                                     options: WriterOptions(compressionThreads: 4)).commit()
            let limits = CompressedTarSplicePlan.limits(format, options: WriterOptions())
            XCTAssertEqual(try verifyLayout(url, format: format, limits: limits), try Data(contentsOf: source))
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.entries.map(\.name), items.map(\.name))
            for (entry, item) in zip(reader.entries, items) { XCTAssertEqual(try reader.read(entry), item.data) }
        }
    }

    func testBzip2HeaderGroupLargerThanChunkLimit() throws {
        let directory = try TestSupport.directory("tar-chunk-large-pax")
        var expected: Data?
        for threads in [1, 4, 8] {
            let url = directory.appendingPathComponent("\(threads).tar.bz2")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let writer = TarWriter(output: FileHandle(fileDescriptor: fd, closeOnDealloc: true), url: url,
                compressor: try ParallelBzip2Compressor(level: 1, threads: threads))
            var read = false
            try writer.add(name: String(repeating: "p", count: 500_053), mode: 0o100644, size: 1,
                           date: TestSupport.date, owners: nil, hardLink: nil) { _ in
                defer { read = true }
                return read ? Data() : Data([7])
            }
            try writer.finish()
            let raw = try verifyLayout(url, format: .tarBzip2, limit: 500_000)
            let member = try XCTUnwrap(TarChunkCutterTestSupport.members(in: raw).first)
            XCTAssertGreaterThan(member.dataStart - member.groupStart, 500_000)
            let bytes = try Data(contentsOf: url)
            if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
        }
    }

    func testTarWriterRecordsOptionalMemberLayouts() throws {
        let directory = try TestSupport.directory("tar-member-layouts")
        for enabled in [false, true] {
            let url = directory.appendingPathComponent("\(enabled).tar")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let writer = TarWriter(output: FileHandle(fileDescriptor: fd, closeOnDealloc: true), url: url,
                                   compressor: nil, recordsMemberLayout: enabled)
            for item in items(limits: .init(uniform: 8192)) {
                var offset = 0
                try writer.add(name: item.name, mode: item.mode, size: UInt64(item.data.count),
                               date: TestSupport.date, owners: nil, hardLink: nil) { count in
                    let end = min(offset + count, item.data.count)
                    defer { offset = end }
                    return item.data.subdata(in: offset..<end)
                }
            }
            try writer.finish()
            let expected = enabled ? try TarChunkCutterTestSupport.members(in: Data(contentsOf: url)) : []
            XCTAssertEqual(writer.memberLayouts.map { [$0.groupStart, $0.dataStart, $0.end] },
                           expected.map { [UInt64($0.groupStart), UInt64($0.dataStart), UInt64($0.end)] })
        }
    }

    func testXZHeaderGroupLargerThanPieceLimit() throws {
        let directory = try TestSupport.directory("xz-large-pax")
        let limits = limits(.tarXZ)
        var expected: Data?
        for threads in [1, 4, 8] {
            let url = directory.appendingPathComponent("\(threads).tar.xz")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let writer = TarWriter(output: FileHandle(fileDescriptor: fd, closeOnDealloc: true), url: url,
                compressor: try ParallelXZCompressor(
                    threads: threads, chunkSize: limits.piece, packingSize: limits.packing))
            var read = false
            try writer.add(name: String(repeating: "p", count: limits.piece + 53), mode: 0o100644, size: 1,
                           date: TestSupport.date, owners: nil, hardLink: nil) { _ in
                defer { read = true }
                return read ? Data() : Data([7])
            }
            try writer.finish()
            let raw = try verifyLayout(url, format: .tarXZ, limits: limits)
            let member = try XCTUnwrap(TarChunkCutterTestSupport.members(in: raw).first)
            XCTAssertGreaterThan(member.dataStart - member.groupStart, limits.piece)
            let bytes = try Data(contentsOf: url)
            if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
        }
    }

    private func compressor(_ format: GyoshukuKit.ArchiveFormat, small: Bool) throws -> any TarCompressor {
        switch format {
        case .tarGzip: try GzipCompressor(level: 6, threads: 4, blockSize: small ? 8192 : DeflateBlock.size)
        case .tarBzip2: try ParallelBzip2Compressor(level: small ? 1 : 9, threads: 4)
        default: try ParallelXZCompressor(threads: 4, chunkSize: small ? 262_144 : ParallelXZCompressor.defaultBlockSize,
                                          packingSize: small ? 65_536 : nil)
        }
    }

    private func serial(_ raw: Data, ranges: [Range<Int>], format: GyoshukuKit.ArchiveFormat,
                        rollingDictionary: Bool) throws -> Data {
        var result = Data(), records = Data(), previous = Data()
        if format == .tarGzip { result.append(contentsOf: [31, 139, 8, 0, 0, 0, 0, 0, 0, 3]) }
        if format == .tarXZ { result.append(XZFraming.streamHeader) }
        for (index, range) in ranges.enumerated() {
            let input = raw.subdata(in: range)
            switch format {
            case .tarGzip:
                let dictionary = rollingDictionary ? raw.subdata(in: max(0, range.lowerBound - 32_768)..<range.lowerBound) : previous
                result.append(try DeflateBlock.encode(.init(input: input, dictionary: dictionary,
                                                           final: index == ranges.count - 1), level: 6))
                previous = DeflateBlock.dictionary(from: input)
            case .tarBzip2:
                result.append(try Bzip2StreamEncoder.encode(input, level: 9))
            default:
                records.append(try XZFraming.emitBlock(LZMA2Compressor.encode(input), crc: updateCRC(0, input)) { result.append($0) })
            }
        }
        if format == .tarGzip { result.le(updateCRC(0, raw)); result.le(UInt32(truncatingIfNeeded: raw.count)) }
        if format == .tarXZ {
            try XZFraming.emitIndexAndFooter(records: records, blockCount: UInt64(ranges.count)) { result.append($0) }
        }
        return result
    }
}
