import Foundation
import Darwin
import Synchronization
import XCTest
@_spi(ZipRawLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

enum ReencryptionSupport {
    static let old = "古い-password"
    static let new = "新しい-password"
    static let items: [(String, Data)] = [0, 19, 20, 21].map { ("size-\($0)", Data(repeating: 65, count: $0)) }
        + [("body", Data(String(repeating: "保存した圧縮データ\n", count: 4000).utf8))]

    static func reader(_ url: URL, password: String? = nil) throws -> ArchiveReader {
        var options = ArchiveUpdater.readerOptions
        options.password = password
        return try ArchiveReader.open(url: url, options: options)
    }

    static func fixture(_ directory: URL, name: String = "source.zip", password: String? = nil,
                        encryption: ZipEncryption = .aes256, method: CompressionMethod = .deflate,
                        items: [(String, Data)] = items, special: Bool = false,
                        salt: UInt8 = 3) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try ArchiveWriter.create(url: url, format: .zip, options: .init(compressionMethod: method,
            useCompressionHeuristic: false, password: password, zipEncryption: encryption, compressionThreads: 1),
            zipSalt: { Data(repeating: salt, count: 16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        for (name, data) in items { try writer.add(data: data, as: name, modificationDate: ZipTestSupport.date, permissions: 0o640) }
        if special {
            let disk = directory.appendingPathComponent("disk-dir")
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
            var times = [timeval(tv_sec: 1_700_000_001, tv_usec: 0), timeval(tv_sec: 1_700_000_001, tv_usec: 0)]
            XCTAssertEqual(utimes(disk.path, &times), 0)
            try writer.add(contentsOf: disk, as: "directory/")
            let link = directory.appendingPathComponent("disk-link")
            if !FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "disk-dir")
            }
            XCTAssertEqual(lutimes(link.path, &times), 0)
            try writer.add(contentsOf: link, as: "link")
        }
        try writer.finish()
        return url
    }

    @discardableResult
    static func convert(_ source: URL, to output: URL, current: String?, password: String?, encryption: ZipEncryption = .aes256,
                        threads: Int = 3) throws -> ArchiveUpdater {
        let updater = try ArchiveUpdater.open(url: source, output: output,
            options: .init(password: password, zipEncryption: encryption, compressionThreads: threads))
        try updater.reencryptExistingEntries(currentPassword: current)
        try updater.commit()
        return updater
    }

    static func assertStoredEqual(_ source: URL, _ output: URL, current: String?, password: String?, expanded: Bool = true,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let input = try reader(source, password: current), result = try reader(output, password: password)
        XCTAssertEqual(input.entries.count, result.entries.count, file: file, line: line)
        for index in input.entries.indices {
            XCTAssertEqual(try input.zipStoredPayloadStream(at: index).readAll(),
                           try result.zipStoredPayloadStream(at: index).readAll(), file: file, line: line)
            XCTAssertEqual(try input.zipRawRecordLayout(at: index)?.compressionMethod,
                           try result.zipRawRecordLayout(at: index)?.compressionMethod, file: file, line: line)
            if expanded { XCTAssertEqual(try input.read(input.entries[index]), try result.read(result.entries[index]), file: file, line: line) }
        }
    }

    static func assertFailure(_ source: URL, password: String?, current: String?, encryption: ZipEncryption = .aes256,
                              modify: (ArchiveUpdater) throws -> Void = { _ in },
                              check: (Error) -> Void = { error in
                                  guard case UpdaterError.reencryptionFailed = error else { return XCTFail("Unexpected: \(error)") }
                              }) throws {
        let parent = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let before = try Data(contentsOf: source), info = try ZipP1Support.info(source)
        let updater = try ArchiveUpdater.open(url: source, output: parent.appendingPathComponent("output.zip"),
            options: .init(password: password, zipEncryption: encryption))
        try updater.reencryptExistingEntries(currentPassword: current)
        try modify(updater)
        XCTAssertThrowsError(try updater.commit(), "Expected failure") { check($0) }
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try ZipP1Support.info(source).st_ino, info.st_ino)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
}

final class ZipReencryptionTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let directory = try ZipTestSupport.directory("reencrypt-" + name)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAllWriterTransitionsPreserveStoredBytesAndSelectPasses() throws {
        let directory = try directory("matrix")
        for method in [CompressionMethod.stored, .deflate] {
            for inputMode in 0..<3 {
                let current = inputMode == 0 ? nil : ReencryptionSupport.old
                let source = try ReencryptionSupport.fixture(directory, name: "input-\(method)-\(inputMode).zip", password: current,
                    encryption: inputMode == 1 ? .zipCrypto : .aes256, method: method, special: true)
                let original = try ReencryptionSupport.reader(source, password: current)
                for targetMode in 0..<3 {
                    let password = targetMode == 0 ? nil : ReencryptionSupport.new
                    let output = directory.appendingPathComponent("output-\(method)-\(inputMode)-\(targetMode).zip")
                    let events = Mutex<[ZipReencryption.Event]>([])
                    let updater = try ZipReencryption.$observer.withValue({ event in events.withLock { $0.append(event) } }) {
                        try ReencryptionSupport.convert(source, to: output, current: current, password: password,
                            encryption: targetMode == 1 ? .zipCrypto : .aes256)
                    }
                    try ReencryptionSupport.assertStoredEqual(source, output, current: current, password: password)
                    let changed = inputMode != 0 || targetMode != 0
                    XCTAssertEqual(updater.lastCommitStrategy, changed ? .rebuild : .unchanged)
                    let recorded = events.withLock { $0 }
                    let ae2 = original.entries.filter { $0.kind == .file && ($0.uncompressedSize ?? 0) >= 20 }.count
                    XCTAssertEqual(recorded.filter { $0.phase == .passA }.count, inputMode == 2 && targetMode != 2 ? ae2 : 0)
                    let expectedV2 = inputMode == 1 ? ReencryptionSupport.items.count :
                        ((inputMode == 2 && targetMode != 2) || (inputMode == 0 && targetMode == 2) ? ae2 : 0)
                    XCTAssertEqual(recorded.filter { $0.phase == .v2 }.count, expectedV2)
                    let result = try ReencryptionSupport.reader(output, password: password)
                    for entry in result.entries {
                        XCTAssertEqual(entry.isEncrypted, targetMode != 0 && entry.kind == .file)
                        if changed && entry.kind == .file { XCTAssertFalse(try XCTUnwrap(result.zipRawRecordLayout(at: entry.index)).hasDataDescriptor) }
                    }
                }
            }
        }
    }

    func testGoldenMatchesWriterForAESAndStoredZipCryptoHeaders() throws {
        let directory = try directory("golden")
        for method in [CompressionMethod.stored, .deflate] {
            let plain = try ReencryptionSupport.fixture(directory, name: "plain-\(method).zip", method: method, special: true)
            let aes = try ReencryptionSupport.fixture(directory, name: "aes-\(method).zip", password: ReencryptionSupport.old, method: method, special: true)
            let new = try ReencryptionSupport.fixture(directory, name: "new-\(method).zip", password: ReencryptionSupport.new, method: method, special: true, salt: 4)
            for (label, source, current, password, expected, salt) in [
                ("set", plain, nil, Optional(ReencryptionSupport.old), aes, UInt8(3)),
                ("remove", aes, Optional(ReencryptionSupport.old), nil, plain, 3),
                ("change", aes, Optional(ReencryptionSupport.old), Optional(ReencryptionSupport.new), new, 4)
            ] {
                let output = directory.appendingPathComponent("\(method)-\(label).zip")
                try ArchiveUpdater.$testingRandomBytes.withValue({ Data(repeating: salt, count: $0) }) {
                    try ReencryptionSupport.convert(source, to: output, current: current, password: password)
                }
                XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: expected), "\(method) \(label)")
            }
        }
        let plain = try ReencryptionSupport.fixture(directory, name: "zc-plain.zip", method: .stored)
        let direct = try ReencryptionSupport.fixture(directory, name: "zc-direct.zip", password: ReencryptionSupport.new, encryption: .zipCrypto, method: .stored)
        let output = directory.appendingPathComponent("zc-output.zip")
        try ReencryptionSupport.convert(plain, to: output, current: nil, password: ReencryptionSupport.new, encryption: .zipCrypto)
        let expected = try ReencryptionSupport.reader(direct), actual = try ReencryptionSupport.reader(output)
        let d = try Data(contentsOf: direct), o = try Data(contentsOf: output)
        for index in expected.entries.indices {
            let er = try XCTUnwrap(expected.zipRawRecordLayout(at: index)), ar = try XCTUnwrap(actual.zipRawRecordLayout(at: index))
            XCTAssertEqual(d.subdata(in: Int(er.recordRange.lowerBound)..<Int(er.payloadRange.lowerBound)),
                           o.subdata(in: Int(ar.recordRange.lowerBound)..<Int(ar.payloadRange.lowerBound)))
        }
        let ds = try ZipUpdateSource(url: direct), os = try ZipUpdateSource(url: output)
        let dl = try ZipUpdateLayout(source: ds), ol = try ZipUpdateLayout(source: os)
        XCTAssertEqual(try ds.bytes(at: dl.centralOffset, count: Int(dl.centralSize)), try os.bytes(at: ol.centralOffset, count: Int(ol.centralSize)))
        try ReencryptionSupport.assertStoredEqual(plain, output, current: nil, password: ReencryptionSupport.new)
    }

    func testNoOpReservationAndPasswordComparisonUsesUTF8() throws {
        let directory = try directory("noop")
        for (label, items, password, current) in [
            ("empty", [(String, Data)](), nil, nil),
            ("plain", ReencryptionSupport.items, nil, nil),
            ("same", ReencryptionSupport.items, Optional("secret"), Optional("secret")),
            ("unchecked", ReencryptionSupport.items, Optional("wrong"), Optional("wrong"))
        ] {
            let source = try ReencryptionSupport.fixture(directory, name: label + ".zip", password: password == nil ? nil : "secret", items: items)
            let output = directory.appendingPathComponent(label + "-out.zip")
            let updater = try ReencryptionSupport.convert(source, to: output, current: current, password: password)
            XCTAssertEqual(updater.lastCommitStrategy, .unchanged)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: output))
        }
        let nfc = "caf\u{e9}", nfd = "cafe\u{301}"
        XCTAssertEqual(nfc, nfd)
        let source = try ReencryptionSupport.fixture(directory, name: "unicode.zip", password: nfc)
        let output = directory.appendingPathComponent("unicode-output.zip")
        XCTAssertEqual(try ReencryptionSupport.convert(source, to: output, current: nfc, password: nfd).lastCommitStrategy, .rebuild)
        try ReencryptionSupport.assertStoredEqual(source, output, current: nfc, password: nfd)
    }

    func testMixedEditsAndReservationOrderUseStagedRebuild() throws {
        let directory = try directory("mixed")
        let source = try ReencryptionSupport.fixture(directory)
        var results: [Data] = []
        for order in 0..<3 {
            let output = directory.appendingPathComponent("out-\(order).zip")
            try ArchiveUpdater.$testingRandomBytes.withValue(ZipP1Support.salt) {
                let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: ReencryptionSupport.new))
                if order == 0 { try updater.reencryptExistingEntries(currentPassword: nil) }
                if order == 2 { try updater.add(data: Data([4, 5]), as: "added", modificationDate: ZipTestSupport.date) }
                try updater.rename(entryAt: 1, to: "renamed")
                try updater.remove(entriesAt: [0])
                if order != 2 { try updater.add(data: Data([4, 5]), as: "added", modificationDate: ZipTestSupport.date) }
                if order != 0 { try updater.reencryptExistingEntries(currentPassword: nil) }
                try updater.commit()
                XCTAssertEqual(updater.lastCommitStrategy, .stagedRebuild)
            }
            let reader = try ReencryptionSupport.reader(output, password: ReencryptionSupport.new)
            XCTAssertEqual(reader.entries.map(\.name), ["renamed", "size-20", "size-21", "body", "added"])
            for entry in reader.entries { _ = try reader.read(entry); XCTAssertTrue(entry.isEncrypted) }
            results.append(try Data(contentsOf: output))
        }
        XCTAssertEqual(results[0], results[1]); XCTAssertEqual(results[1], results[2])
    }

    func testZeroConversionsPreserveP1GBytesAndStrategiesWithEdits() throws {
        let directory = try directory("noop-edits")
        let source = try ReencryptionSupport.fixture(directory, password: "same")
        for mode in 0..<3 {
            var results: [Data] = [], strategies: [ArchiveUpdater.CommitStrategy?] = []
            for reserve in [false, true] {
                let output = directory.appendingPathComponent("\(mode)-\(reserve).zip")
                try ArchiveUpdater.$testingRandomBytes.withValue(ZipP1Support.salt) {
                    let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "same"))
                    if reserve { try updater.reencryptExistingEntries(currentPassword: "same") }
                    if mode == 0 { try updater.rename(entryAt: 0, to: "size-X") }
                    if mode == 1 { try updater.remove(entriesAt: [0]); try updater.rename(entryAt: 1, to: "longer") }
                    if mode == 2 { try updater.add(data: Data([1]), as: "new", modificationDate: ZipTestSupport.date) }
                    try updater.commit()
                    strategies.append(updater.lastCommitStrategy)
                }
                results.append(try Data(contentsOf: output))
            }
            XCTAssertEqual(results[0], results[1]); XCTAssertEqual(strategies[0], strategies[1])
        }
        let folders = directory.appendingPathComponent("folders.zip")
        let writer = try ArchiveWriter.create(url: folders)
        try writer.addDirectory("first"); try writer.addDirectory("directory")
        try writer.finish()
        let output = directory.appendingPathComponent("folders-out.zip")
        XCTAssertEqual(try ReencryptionSupport.convert(folders, to: output, current: nil, password: "new").lastCommitStrategy, .unchanged)
        XCTAssertEqual(try Data(contentsOf: folders), try Data(contentsOf: output))
    }

    func testProgressIncludesConversionAndIsMonotone() throws {
        let directory = try directory("progress")
        let source = try ReencryptionSupport.fixture(directory, method: .stored,
            items: [("large", Data(repeating: 7, count: 9 * 1024 * 1024))])
        let output = directory.appendingPathComponent("out.zip")
        let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "new"))
        try updater.reencryptExistingEntries(currentPassword: nil)
        var progress: [ArchiveUpdater.CommitProgress] = []
        try updater.commit { progress.append($0) }
        let last = try XCTUnwrap(progress.last)
        XCTAssertEqual(last.completedBytes, last.totalBytes)
        XCTAssertGreaterThan(last.totalBytes, UInt64(try Data(contentsOf: output).count))
        XCTAssertGreaterThan(progress.count, 3)
        for pair in zip(progress, progress.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.completedBytes, pair.1.completedBytes)
            XCTAssertEqual(pair.0.totalBytes, pair.1.totalBytes)
        }
        let before = try Data(contentsOf: source)
        let cancel = try ArchiveUpdater.open(url: source, options: .init(password: "new"))
        try cancel.reencryptExistingEntries(currentPassword: nil)
        XCTAssertThrowsError(try cancel.commit { if $0.completedBytes > 0 { throw CancellationError() } }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testWrongPasswordsMissingPasswordAndHMACTampering() throws {
        let directory = try directory("passwords")
        for encryption in [ZipEncryption.aes256, .zipCrypto] {
            let source = try ReencryptionSupport.fixture(directory, name: "\(encryption).zip", password: "right", encryption: encryption)
            try ReencryptionSupport.assertFailure(source, password: "new", current: "wrong", check: { XCTAssertEqual($0 as? KaitoError, .wrongPassword) })
            try ReencryptionSupport.assertFailure(source, password: nil, current: nil, check: { XCTAssertEqual($0 as? KaitoError, .passwordRequired) })
        }
        let source = try ReencryptionSupport.fixture(directory, name: "hmac.zip", password: "right")
        let raw = try XCTUnwrap(ReencryptionSupport.reader(source).zipRawRecordLayout(at: 0))
        var data = try Data(contentsOf: source)
        data[Int(raw.payloadRange.upperBound - 1)] ^= 1
        try data.write(to: source)
        try ReencryptionSupport.assertFailure(source, password: "new", current: "right", check: { XCTAssertEqual($0 as? KaitoError, .wrongPassword) })
    }

    func testZipCryptoVerifierCollisionIsRejectedByV2() throws {
        let directory = try directory("collision")
        let source = try ReencryptionSupport.fixture(directory, password: "right", encryption: .zipCrypto, method: .stored,
            items: [("payload", Data(repeating: 17, count: 100))])
        let reader = try ReencryptionSupport.reader(source)
        var collision: String?
        for index in 0..<4096 {
            reader.password = "wrong-\(index)"
            if (try? reader.zipStoredPayloadStream(at: 0).readAll()) != nil { collision = reader.password; break }
        }
        let password = try XCTUnwrap(collision)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        for target in [ZipEncryption.aes256, .zipCrypto] {
            try ReencryptionSupport.assertFailure(source, password: "new", current: password, encryption: target, check: {
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            })
        }
    }

    func testOutputTamperingAlwaysUsesReencryptionFailedAndCleansOutput() throws {
        let directory = try directory("tampering")
        let source = try ReencryptionSupport.fixture(directory)
        for mutation in 0..<6 {
            try ReencryptionSupport.assertFailure(source, password: "new", current: nil, modify: { updater in
                updater.afterRebuild = { url in
                    let source = try ZipUpdateSource(url: url), layout = try ZipUpdateLayout(source: source)
                    let reader = try ReencryptionSupport.reader(url)
                    let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: 2))
                    let directory = try ZipCentralDirectory.validate(source: source, reader: reader, centralOffset: layout.centralOffset, centralSize: layout.centralSize)
                    let cd = Int(layout.centralOffset) + directory.records[2].centralRange.lowerBound
                    var bytes = try Data(contentsOf: url)
                    switch mutation {
                    case 0: bytes[Int(raw.payloadRange.lowerBound) + 18] ^= 1
                    case 1: bytes[cd + 16] ^= 1
                    case 2:
                        let header = try ZipRebuild.CentralHeader(bytes: directory.bytes, range: directory.records[2].centralRange)
                        let aes = try XCTUnwrap(ZipRebuild.extraFields(header.extra).first { $0.id == 0x9901 })
                        bytes[cd + 46 + header.name.count + aes.range.lowerBound + 4] = 1
                    case 3: bytes[Int(raw.recordRange.lowerBound) + 14] ^= 1
                    case 4: bytes[Int(raw.recordRange.lowerBound) + 8] ^= 1
                    default: bytes.removeLast()
                    }
                    try bytes.write(to: url)
                }
            })
        }
    }

    func testMaterialSaltMismatchAndV3EncryptionKeyMixup() throws {
        let directory = try directory("material")
        let source = try ReencryptionSupport.fixture(directory, password: "old", items: [("ae2", Data(repeating: 1, count: 100))])
        for wrongSalt in [true, false] {
            let events = Mutex<[ZipReencryption.Phase]>([])
            try ZipReencryption.$observer.withValue({ event in events.withLock { $0.append(event.phase) } }) {
                try ZipReencryption.$testingKeyMaterial.withValue({ _, keys in
                    let output = keys.output!
                    var bytes = output.bytes, salt = output.salt
                    if wrongSalt { salt[0] ^= 1 } else { bytes[0] ^= 1 }
                    keys.output = try ZipAESKeyMaterial(salt: salt, strength: 3, bytes: bytes)
                }) {
                    try ReencryptionSupport.assertFailure(source, password: "new", current: "old")
                }
            }
            if !wrongSalt {
                XCTAssertTrue(events.withLock { $0.contains(.v1) && $0.contains(.v3) })
                XCTAssertFalse(events.withLock { $0.contains(.v2) })
            }
        }
    }

    func testCancellationAtEveryConversionStageAndStateRules() throws {
        let directory = try directory("cancel")
        let aes = try ReencryptionSupport.fixture(directory, name: "aes.zip", password: "old")
        for phase in [ZipReencryption.Phase.deriveInput, .deriveOutput, .derivationWait, .passA, .convert, .v0, .v1, .v2, .v3] {
            try ZipReencryption.$observer.withValue({ event in if event.phase == phase { throw CancellationError() } }) {
                try ReencryptionSupport.assertFailure(aes, password: phase == .passA || phase == .v2 ? nil : "new", current: "old", check: {
                    XCTAssertTrue($0 is CancellationError)
                })
            }
        }
        let twice = try ArchiveUpdater.open(url: aes)
        try twice.reencryptExistingEntries(currentPassword: "old")
        XCTAssertThrowsError(try twice.reencryptExistingEntries(currentPassword: "old")) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
        XCTAssertThrowsError(try twice.commit()) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
        let done = try ArchiveUpdater.open(url: aes)
        try done.commit()
        XCTAssertThrowsError(try done.reencryptExistingEntries(currentPassword: "old")) { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
    }

    func testUnshiftedDirectoriesAreNotReadDuringCommit() throws {
        let directory = try directory("reads")
        let source = directory.appendingPathComponent("source.zip")
        let writer = try ArchiveWriter.create(url: source, options: .init(password: "old"))
        for index in 0..<100 { try writer.addDirectory("folder-\(index)") }
        try writer.add(data: Data(repeating: 1, count: 21), as: "last")
        try writer.finish()
        let input = try ReencryptionSupport.reader(source)
        let raw = try XCTUnwrap(input.zipRawRecordLayout(at: 100))
        let inode = UInt64(try ZipP1Support.info(source).st_ino)
        let updater = try ArchiveUpdater.open(url: source)
        try updater.reencryptExistingEntries(currentPassword: "old")
        let events = ZipIOEvents()
        try ZipUpdateSource.$readObserver.withValue(events.read) { try updater.commit() }
        let reads = events.events.filter { $0.inode == inode }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0.offset >= raw.recordRange.lowerBound })
    }

    func testParallelDerivationMatchesSerialAndObserverUsesCommitThread() throws {
        let directory = try directory("parallel")
        let source = try ReencryptionSupport.fixture(directory, password: "old", items: (0..<40).map { ("f-\($0)", Data([UInt8($0)])) })
        var outputs: [Data] = []
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let expectedThread = threadID
        for threads in [1, 8] {
            let counter = Mutex(0)
            let events = Mutex<[ZipReencryption.Event]>([])
            let output = directory.appendingPathComponent("out-\(threads).zip")
            try ArchiveUpdater.$testingRandomBytes.withValue({ count in
                let ordinal = counter.withLock { value in value += 1; return value }
                return Data(repeating: UInt8(ordinal), count: count)
            }) {
                try ZipReencryption.$observer.withValue({ event in
                    var current: UInt64 = 0
                    pthread_threadid_np(nil, &current)
                    XCTAssertEqual(current, expectedThread)
                    events.withLock { $0.append(event) }
                }) {
                    try ReencryptionSupport.convert(source, to: output, current: "old", password: "new", threads: threads)
                }
            }
            XCTAssertEqual(events.withLock { $0.filter { $0.phase == .deriveInput }.map(\.index) }, Array(0..<40))
            XCTAssertEqual(events.withLock { $0.filter { $0.phase == .deriveOutput }.map(\.index) }, Array(0..<40))
            outputs.append(try Data(contentsOf: output))
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }

    func testSameSizeConversionAndAppendUseRebuildThenAppend() throws {
        let directory = try directory("same-size-append")
        let source = try ReencryptionSupport.fixture(directory, password: "old")
        let output = directory.appendingPathComponent("out.zip")
        let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "new"))
        try updater.reencryptExistingEntries(currentPassword: "old")
        try updater.add(data: Data([1]), as: "added")
        try updater.commit()
        XCTAssertEqual(updater.lastCommitStrategy, .rebuildThenAppend)
        let reader = try ReencryptionSupport.reader(output, password: "new")
        for entry in reader.entries { _ = try reader.read(entry) }
    }

    func testOriginalChangeIsRejectedAndDeletedEncryptedEntriesNeedNoPassword() throws {
        let directory = try directory("changed")
        let source = try ReencryptionSupport.fixture(directory, password: "old")
        let updater = try ArchiveUpdater.open(url: source, options: .init(password: "new"))
        try updater.reencryptExistingEntries(currentPassword: "old")
        var modified = try Data(contentsOf: source)
        modified.append(0)
        try modified.write(to: source)
        XCTAssertThrowsError(try updater.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
        XCTAssertEqual(try Data(contentsOf: source), modified)
        let encrypted = try ReencryptionSupport.fixture(directory, name: "remove.zip", password: "old", items: [("removed", Data([1]))])
        let remove = try ArchiveUpdater.open(url: encrypted)
        try remove.reencryptExistingEntries(currentPassword: nil)
        try remove.remove(entriesAt: [0])
        try remove.commit()
        XCTAssertEqual(try ArchiveUpdater.probe(url: encrypted).entryCount, 0)
    }

    func testInputSaltChangedAfterDerivationIsWrapped() throws {
        let directory = try directory("input-salt")
        let source = try ReencryptionSupport.fixture(directory, password: "old")
        let raw = try XCTUnwrap(ReencryptionSupport.reader(source).zipRawRecordLayout(at: 0))
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("out.zip")
        let updater = try ArchiveUpdater.open(url: source, options: .init(password: "new"))
        try updater.reencryptExistingEntries(currentPassword: "old")
        try ZipReencryption.$observer.withValue({ event in
            if event.phase == .convert && event.index == 0 {
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.seek(toOffset: raw.payloadRange.lowerBound)
                try handle.write(contentsOf: Data([original[Int(raw.payloadRange.lowerBound)] ^ 1]))
            }
        }) {
            XCTAssertThrowsError(try updater.commit()) {
                guard case UpdaterError.reencryptionFailed = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        var changed = original; changed[Int(raw.payloadRange.lowerBound)] ^= 1
        XCTAssertEqual(try Data(contentsOf: source), changed)
    }
}
