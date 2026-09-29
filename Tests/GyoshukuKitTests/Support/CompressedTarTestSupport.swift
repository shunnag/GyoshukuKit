import Foundation
import Darwin
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

enum CompressedTarTestSupport {
    typealias Format = GyoshukuKit.ArchiveFormat
    static let formats: [Format] = [.tarGzip, .tarBzip2, .tarXZ]
    static var readerOptions: ReaderOptions {
        var options = TestSupport.editingReaderOptions
        options.recordsTarEditLayout = true
        return options
    }
    static func open(_ url: URL) throws -> sending ArchiveReader {
        let source = try FileByteSource(url: url)
        let bytes = try TarLayout.bytes(source, at: 0, count: Int(min(6, source.length)))
        let suffix = bytes.starts(with: [0x1f, 0x8b]) ? "tar.gz" : bytes.starts(with: [0x42, 0x5a]) ? "tar.bz2" : "tar.xz"
        return try ArchiveReader.open(source: source, sourceURL: url.appendingPathExtension(suffix), options: readerOptions)
    }
    static func fixture(_ root: URL, _ format: Format, large: Bool = true, aligned: Bool = true) throws -> URL {
        let raw = root.appendingPathComponent("input.tar")
        let writer = try ArchiveWriter.create(url: raw, format: .tar)
        let size = large ? CompressedTarSplicePlan.limits(format, options: WriterOptions()).piece + 129 : 8192
        for name in ["large-A", "large-B"] {
            var body = Data(repeating: 37, count: size)
            var random = TestCorpus.XorShift64(state: name == "large-A" ? 17 : 31)
            let entropy = OptInGate.isOn("GYOSHUKU_P3_REPETITIVE_FIXTURE") ? 0 : min(size, 65536)
            for index in 0..<entropy {
                body[index] = UInt8(truncatingIfNeeded: random.next())
            }
            try writer.add(data: body, as: name, modificationDate: TestSupport.date)
        }
        for index in 0..<24 {
            try writer.add(data: Data(repeating: UInt8(index), count: 65536), as: String(format: "item-%03d", index), modificationDate: TestSupport.date)
        }
        let path = "cafe\u{301}/" + String(repeating: "n", count: 120)
        try writer.add(data: Data([99]), as: path, modificationDate: TestSupport.date)
        try writer.finish()
        let output = root.appendingPathComponent("source." + format.testFileExtension)
        try compress(raw, to: output, format: format, aligned: aligned)
        return output
    }
    static func compress(_ raw: URL, to output: URL, format: Format, aligned: Bool = true,
                         options: WriterOptions = WriterOptions(), packingSize: Int? = nil) throws {
        let source = try ArchiveFileSource(url: raw)
        let codec: any TarCompressor
        switch format {
        case .tarGzip: codec = try GzipCompressor(level: options.deflateLevel, threads: options.resolvedCompressionThreads)
        case .tarBzip2: codec = try ParallelBzip2Compressor(level: options.bzip2Level, threads: options.resolvedCompressionThreads)
        default: codec = try ParallelXZCompressor(threads: options.resolvedCompressionThreads, packingSize: packingSize)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        func emit(_ bytes: Data) throws { try handle.write(contentsOf: bytes) }
        func feed(_ range: Range<UInt64>) throws {
            var position = range.lowerBound
            while position < range.upperBound {
                let count = Int(min(262144, range.upperBound - position))
                try codec.write(source.bytes(at: position, count: count), finish: false, emit: emit)
                position += UInt64(count)
            }
        }
        if aligned {
            let layout = try TarLayout.walk(source: source, range: 0..<source.length) { _, _, _ in }
            for unit in layout.units {
                codec.beginMember(headerLength: unit.dataStart - unit.groupStart, bodyLength: unit.paddedEnd - unit.dataStart)
                try feed(unit.range)
            }
            codec.beginEndOfArchive()
            try feed(layout.membersEnd..<source.length)
        } else { try feed(0..<source.length) }
        try codec.write(Data(), finish: true, emit: emit)
    }

    static func packingFixture(_ root: URL, oldPacking: Bool = false, bodyExcess: Int = 100_000) throws -> URL {
        let raw = root.appendingPathComponent("input.tar"), output = root.appendingPathComponent("packing.tar.xz")
        let plain = try ArchiveWriter.create(url: raw, format: .tar)
        let writer = try oldPacking ? nil : ArchiveWriter.create(url: output, format: .tarXZ)
        let size = CompressedTarSplicePlan.limits(.tarXZ, options: WriterOptions()).packing + bodyExcess
        let seed = LHATestSupport.random(65_536)
        func add(_ name: String, size: Int) throws {
            var body = Data(repeating: 37, count: size)
            body.replaceSubrange(0..<min(size, seed.count), with: seed.prefix(size))
            try plain.add(data: body, as: name, modificationDate: TestSupport.date)
            try writer?.add(data: body, as: name, modificationDate: TestSupport.date)
        }
        for index in 0..<12 { try add("before-\(index)", size: 128 * 1024) }
        try add("medium", size: size)
        for index in 0..<12 { try add("after-\(index)", size: 128 * 1024) }
        try plain.finish()
        if let writer { try writer.finish() }
        else { try compress(raw, to: output, format: .tarXZ, packingSize: ParallelXZCompressor.defaultBlockSize) }
        return output
    }
    static func splice(_ result: CompressedTarCommitResult) -> CompressedTarSplice {
        CompressedTarSplice(segments: result.segments.map {
            switch $0 { case .encoded(let output): .encoded(output: output); case .reused(let output, let base): .reused(output: output, base: base) }
        })
    }
    /// KaitoKit の K5 検証（design.md §6「圧縮 tar の区切り単位の更新」）で splice を開く。
    static func spliceVerifiedReader(_ output: URL, base: TarEditingSnapshot, result: CompressedTarCommitResult) throws -> sending ArchiveReader {
        try ArchiveReader.openSplicedCompressedTar(output: FileByteSource(url: output), sourceURL: output.appendingPathExtension(base.container == .gzip ? "tar.gz" : base.container == .bzip2 ? "tar.bz2" : "tar.xz"),
                                                   base: base, splice: splice(result), options: readerOptions)
    }
    static func verify(_ output: URL, base: TarEditingSnapshot, result: CompressedTarCommitResult,
                       oracle: URL? = nil) throws -> sending ArchiveReader {
        let full = try open(output)
        let verified: ArchiveReader
        do { verified = try spliceVerifiedReader(output, base: base, result: result) }
        catch let error as TarSpliceVerificationError where error.reason == .baseNotSpliceable && base.chunkMap == nil {
            if let oracle { try XCTAssertByteSourcesEqual(full.tarEditingSnapshot()!.image, FileByteSource(url: oracle)) }
            return full
        }
        XCTAssertEqual(verified.entries.map(\.name), full.entries.map(\.name))
        for (a, b) in zip(verified.entries, full.entries) {
            XCTAssertEqual(a.kind, b.kind)
            if a.kind != .directory { XCTAssertEqual(try verified.read(a), try full.read(b)) }
        }
        try XCTAssertByteSourcesEqual(verified.tarEditingSnapshot()!.image, full.tarEditingSnapshot()!.image)
        if let oracle { try XCTAssertByteSourcesEqual(verified.tarEditingSnapshot()!.image, FileByteSource(url: oracle)) }
        let info = try ZipEditTestSupport.info(output)
        XCTAssertEqual(result.output.inode, info.st_ino)
        XCTAssertEqual(result.output.size, UInt64(info.st_size))
        XCTAssertEqual(result.output.modificationSeconds, Int64(info.st_mtimespec.tv_sec))
        XCTAssertEqual(result.output.modificationNanoseconds, Int64(info.st_mtimespec.tv_nsec))
        return verified
    }
    @discardableResult
    static func edit(_ source: URL, format: Format, output: URL, options: WriterOptions = WriterOptions(),
                     force: Bool = false, mutate: (any ArchiveEditing) throws -> Void) throws -> CompressedTarCommitResult {
        let reader = try open(source), base = reader.tarEditingSnapshot()!
        let raw = output.appendingPathExtension("base.tar"), oracle = output.appendingPathExtension("oracle.tar")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        var offset: UInt64 = 0
        while offset < base.image.length {
            let count = Int(min(1048576, base.image.length - offset))
            try handle.write(contentsOf: TarLayout.bytes(base.image, at: offset, count: count)); offset += UInt64(count)
        }
        try handle.close()
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: oracle) }
        let plain = try TarUpdater.open(url: raw, output: oracle, options: options)
        try mutate(plain); try plain.commit()
        let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: format, options: options)
        try mutate(editor)
        var updates: [ArchiveUpdater.CommitProgress] = []
        let verificationReads = IOEvents()
        let result = try CompressedTarUpdater.$testingForcesFullEncode.withValue(force) {
            try SplicedArchiveOutput.$verificationReadObserver.withValue(verificationReads.write) {
                try editor.commit { updates.append($0) }
            }
        }
        XCTAssertFalse(updates.isEmpty)
        if result.strategy != .unchanged {
            XCTAssertEqual(updates.first?.totalBytes, result.reencodedImageBytes + result.carriedCompressedBytes + verificationReads.bytes)
        }
        XCTAssertEqual(updates.first?.completedBytes, 0)
        XCTAssertEqual(updates.last?.completedBytes, updates.last?.totalBytes)
        XCTAssertTrue(updates.allSatisfy { $0.totalBytes == updates.first!.totalBytes })
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        XCTAssertEqual(try editor.commit(progress: nil).output, result.output)
        _ = try verify(output, base: base, result: result, oracle: oracle)
        return result
    }
}

/// thread 数と全体の再符号化の有無によらず、同じ編集が同じ byte 列になることを確かめる。
enum CompressedTarDeterminism {
    static func run(_ format: GyoshukuKit.ArchiveFormat) throws {
        let root = try TestSupport.directory("compressed-tar-determinism-\(format)")
        let source = try CompressedTarTestSupport.fixture(root, format)
        var expected: Data?
        for threads in [1, 4, 8] {
            for force in [false, true] {
                let output = root.appendingPathComponent("out-\(threads)-\(force)")
                _ = try CompressedTarTestSupport.edit(source, format: format, output: output,
                    options: .init(compressionThreads: threads), force: force) { try $0.rename(entryAt: 0, to: "large-C") }
                let bytes = try Data(contentsOf: output)
                if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
            }
        }
        for operation in ["append", "delete"] {
            var sizes: [UInt64] = []
            for force in [false, true] {
                let output = root.appendingPathComponent("size-\(operation)-\(force)")
                let result = try CompressedTarTestSupport.edit(source, format: format, output: output, force: force) {
                    if operation == "delete" { try $0.remove(entriesAt: [0]) }
                    else { try $0.add(data: Data(repeating: 65, count: 4096), as: "added", modificationDate: TestSupport.date, permissions: nil) }
                }
                sizes.append(result.output.size)
            }
            XCTAssertLessThanOrEqual(abs(Double(sizes[0]) - Double(sizes[1])), 4096 + Double(sizes[1]) * 0.0005)
            TestSupport.report("TAR-SIZE \(format)\t\(operation)\tsplice=\(sizes[0])\tfull=\(sizes[1])")
        }
    }
}
