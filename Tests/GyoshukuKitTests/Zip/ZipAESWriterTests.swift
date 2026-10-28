import Foundation
import CryptoKit
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ZipAESWriterTests: XCTestCase {
    private let sizes = [0, 1, 15, 16, 17, 4095, 65537]

    func testMixedEntriesMatchSerialBytesWithOrderedTaskLocalSalts() throws {
        let root = try TestSupport.directory("zip-aes-ordered-salts")
        let items = boundaryItems
        // worker / CTR 最適化前の逐次 writer（Swift 6.4）で固定した書庫全体の SHA-256。
        let originalHashes = [
            "stored": "0bbda1aa98834dd9b3134b635a51aff7b11f58d36372c3ea39c50934a77839a5",
            "deflate": "3ed63b47766ab8e3a2debc99d21388e925563884c4be78e6e308589c7225e2f0",
            "bzip2": "26bcfd89ed5f2ddd8bcf5512c08be65b13258a7a422188aa3ba38870caa2134b",
            "lzma": "c77c1cf033f98a0ae77d49be4013e34a5affcabd1f0712f5cb2df36a1ca3a242",
            "xz": "4ff31c3b74eafb1291eb4dc8ea99e4fb4ea371c65e33c69f918ab8cd86bd46c8",
            "zstd": "a39c294021b32bb8b1362d7a434dd70e5daf32b659dd5a8f143a40eb5896fc38",
            "ppmd": "5f4a8435257494c8b6bee5d78f238c2fec6293d1d1eb3b734ffec74a504e0137"
        ]
        for method: CompressionMethod in [.stored, .deflate, .bzip2, .lzma, .xz, .zstd, .ppmd] {
            var baseline: Data?
            for threads in [1, 4, 12] {
                let url = root.appendingPathComponent("\(method)-\(threads).zip")
                let salts = OrderedSalts()
                try EncryptionPrimitives.$testingRandomBytes.withValue({ try salts.next($0) }) {
                    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
                    let writer = ZipWriter(output: try FileHandle(forWritingTo: url), url: url,
                        options: .init(compressionMethod: method, useCompressionHeuristic: false,
                            password: EncryptionTestSupport.password, compressionThreads: threads),
                        deflateBlockSize: 4096, deflateEncoder: DeflateBlock.encode,
                        salt: { try XCTUnwrap(EncryptionPrimitives.testingRandomBytes)(16) })
                    for item in items {
                        var offset = 0
                        let mode = item.kind == .directory ? FileMode.defaultDirectory
                            : item.kind == .symlink ? FileMode.defaultSymlink : UInt16(0o100644)
                        try writer.add(name: item.name, mode: mode, size: UInt64(item.data.count),
                            date: TestSupport.date, atime: nil, owners: nil) { count in
                            let end = min(item.data.count, offset + min(count, 17))
                            defer { offset = end }
                            return item.data.subdata(in: offset..<end)
                        }
                    }
                    try writer.finish(existingCount: 0, comment: Data(), progress: nil, copyCentral: { _ in })
                }
                XCTAssertEqual(salts.count, sizes.count)
                let bytes = try Data(contentsOf: url)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, originalHashes["\(method)"], "\(method), threads=\(threads)")
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method), threads=\(threads)") }
                else { baseline = bytes }
                try EncryptionTestSupport.verify(url, items: items) { $0.kind == .file }
            }
        }
    }

    func testManySmallEntriesMatchSerialBytes() throws {
        let root = try TestSupport.directory("zip-aes-many-small")
        let items = (0..<600).map { index in
            ExpectedEntry(name: "file-\(index)", data: Data(repeating: UInt8(index % 251), count: index % 18))
        }
        for method: CompressionMethod in [.stored, .deflate, .zstd] {
            var baseline: Data?
            for threads in [1, 12] {
                let url = root.appendingPathComponent("\(method)-\(threads).zip")
                let salts = OrderedSalts()
                try EncryptionPrimitives.$testingRandomBytes.withValue({ try salts.next($0) }) {
                    let writer = try ArchiveWriter.create(url: url, format: .zip,
                        options: .init(compressionMethod: method, useCompressionHeuristic: false,
                            password: EncryptionTestSupport.password, compressionThreads: threads),
                        zipSalt: { try XCTUnwrap(EncryptionPrimitives.testingRandomBytes)(16) }, lzmaChunkSize: nil)
                    for item in items {
                        try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                    }
                    try writer.finish()
                }
                XCTAssertEqual(salts.count, items.count)
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method)") } else { baseline = bytes }
                if threads == 12 { try EncryptionTestSupport.verify(url, items: items) { _ in true } }
            }
        }
    }

    func testBatchAndIndividualArchivesUseSameOrderedSalts() throws {
        let root = try TestSupport.directory("zip-aes-batch-salts")
        var additions: [ArchiveAddition] = []
        for item in boundaryItems {
            if item.kind == .directory {
                additions.append(.init(path: item.name, source: .directory(modificationDate: TestSupport.date)))
            } else {
                let url = root.appendingPathComponent("source-\(additions.count)")
                if item.kind == .symlink {
                    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "size-1")
                } else { try item.data.write(to: url) }
                additions.append(.init(path: item.name, source: .contents(of: url)))
            }
        }
        for method: CompressionMethod in [.stored, .deflate, .bzip2, .lzma, .xz, .zstd, .ppmd] {
            var baseline: Data?
            for (variant, threads, batch) in [("serial", 1, false), ("parallel", 12, false), ("batch", 12, true)] {
                try BatchAdditionTestSupport.resetDates(additions)
                let url = root.appendingPathComponent("\(method)-\(variant).zip")
                let salts = OrderedSalts()
                try EncryptionPrimitives.$testingRandomBytes.withValue({ try salts.next($0) }) {
                    try EntryCompressionConfiguration.$testingInputLimit.withValue(32 << 10) {
                        let writer = try ArchiveWriter.create(url: url, format: .zip,
                            options: .init(compressionMethod: method, useCompressionHeuristic: false,
                                password: EncryptionTestSupport.password, compressionThreads: threads),
                            deflateBlockSize: 4096,
                            zipSalt: { try XCTUnwrap(EncryptionPrimitives.testingRandomBytes)(16) }, lzmaChunkSize: nil)
                        if batch { try writer.add(additions, events: nil) }
                        else { try BatchAdditionTestSupport.singles(writer, additions) }
                        try writer.finish()
                    }
                }
                XCTAssertEqual(salts.count, sizes.count)
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(method), \(variant)") } else { baseline = bytes }
                try EncryptionTestSupport.verify(url, items: boundaryItems) { $0.kind == .file }
            }
        }
    }

    func testPlainEntriesDoNotGenerateSalts() throws {
        let root = try TestSupport.directory("zip-plain-no-kdf")
        for method: CompressionMethod in [.stored, .deflate, .zstd] {
            let salts = OrderedSalts()
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(method).zip"), format: .zip,
                options: .init(compressionMethod: method, compressionThreads: 12),
                zipSalt: { try salts.next(16) }, lzmaChunkSize: nil)
            try writer.add(data: Data([1]), as: "one")
            try writer.add(data: Data(), as: "empty")
            try writer.addDirectory("directory")
            try writer.finish()
            XCTAssertEqual(salts.count, 0)
        }
    }

    func testAESAppendPreservesPlainRegularEntries() throws {
        let root = try TestSupport.directory("zip-aes-and-plain-files")
        let source = root.appendingPathComponent("plain.zip")
        let plain = ExpectedEntry(name: "plain", data: Data("plain entry".utf8))
        let writer = try ArchiveWriter.create(url: source)
        try writer.add(data: plain.data, as: plain.name, modificationDate: TestSupport.date)
        try writer.finish()
        var baseline: Data?
        for threads in [1, 12] {
            let url = root.appendingPathComponent("mixed-\(threads).zip")
            try FileManager.default.copyItem(at: source, to: url)
            let salts = OrderedSalts()
            try EncryptionPrimitives.$testingRandomBytes.withValue({ try salts.next($0) }) {
                let updater = try ArchiveUpdater.open(url: url, options: .init(password: EncryptionTestSupport.password,
                    compressionThreads: threads))
                for item in boundaryItems where item.kind == .file {
                    try updater.add(data: item.data, as: item.name, modificationDate: TestSupport.date)
                }
                try updater.commit()
            }
            XCTAssertEqual(salts.count, sizes.count)
            let bytes = try Data(contentsOf: url)
            if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
            try EncryptionTestSupport.verify(url, items: [plain] + boundaryItems.filter { $0.kind == .file }) {
                $0.name != plain.name
            }
        }
    }

    private var boundaryItems: [ExpectedEntry] {
        var items = sizes.map { size in
            ExpectedEntry(name: "size-\(size)", data: Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 17) }))
        }
        items.insert(.init(name: "directory/", kind: .directory), at: 2)
        items.insert(.init(name: "link", data: Data("size-1".utf8), kind: .symlink), at: 5)
        return items
    }

    // @TaskLocal は GCD に伝わらない。呼出し thread と salt の消費順を同時に検査する。
    private final class OrderedSalts: @unchecked Sendable {
        private let lock = NSLock()
        private let thread = Thread.current
        private(set) var count = 0
        func next(_ size: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            XCTAssertTrue(Thread.current === thread, "Salt must be generated on the submitting thread")
            XCTAssertEqual(size, 16)
            defer { count += 1 }
            return Data((0..<size).map { UInt8(truncatingIfNeeded: count * 19 + $0) })
        }
    }
}
