import CryptoKit
import Darwin
import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveRewriterTests: XCTestCase {
    private let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .sevenZip, .lha]
    private let date = ZipTestSupport.date

    private func suffix(_ format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .sevenZip: "7z"
        case .lha: "lha"
        }
    }

    private func directory(_ label: String) throws -> URL {
        let directory = try ZipTestSupport.directory("rewriter-" + label)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func tool(_ name: String) throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/opt/homebrew/bin"]
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw XCTSkip("独立した検査ツールがありません: \(name)")
    }

    @discardableResult
    private func run(_ name: String, _ arguments: [String], in directory: URL) throws -> String {
        let executable = try tool(name)
        let log = directory.appendingPathComponent(UUID().uuidString + ".log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(name) \(arguments):\n\(text)")
        return text
    }

    private func workDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".gyoshuku-rewrite-") }
    }

    private func archive(in directory: URL, filename: String = "source.zip", files: [(String, Data)] = [
        ("zeta.txt", Data("zeta contents".utf8)),
        ("nested/child.txt", Data("nested contents".utf8)),
        ("alpha.txt", Data("alpha contents".utf8))
    ]) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        let writer = try ArchiveWriter.create(url: url)
        for (name, data) in files {
            try writer.add(data: data, as: name, modificationDate: date, permissions: 0o640)
        }
        try writer.finish()
        return url
    }

    private func contents(_ entry: ArchiveEntry, reader: ArchiveReader) throws -> Data {
        if entry.kind == .symlink, let target = entry.formatSpecific["linkPath"] { return Data(target.utf8) }
        return try reader.read(entry)
    }

    private func verifyZIPFixture(to format: GyoshukuKit.ArchiveFormat) throws {
        let directory = try directory("fixture-\(format)")
        let source = try archive(in: directory, files: [
            ("nested/deeper/data.txt", Data(repeating: 0x61, count: 600_123)),
            ("binary.dat", LHATestSupport.random(270_001)), ("zero", Data())
        ])
        let updater = try ArchiveUpdater.open(url: source)
        try updater.addDirectory("nested")
        try updater.addDirectory("nested/deeper")
        try updater.addDirectory("empty")
        if format != .lha {
            let link = directory.appendingPathComponent("disk-link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nested/deeper/data.txt")
            try updater.add(contentsOf: link, as: "link")
        }
        try updater.commit()
        let original = try ArchiveReader.open(url: source)
        let expected = try original.entries.map { try contents($0, reader: original) }
        let output = directory.appendingPathComponent("output." + suffix(format))
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format)
        XCTAssertEqual(rewriter.sourceFormat, .zip)
        XCTAssertFalse(rewriter.hasEncryptedEntries)
        XCTAssertEqual(rewriter.entryNames, original.entries.map(\.name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try workDirectories(in: directory), [])
        try rewriter.commit()
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(reader.entries.map(\.name), original.entries.map(\.name))
        XCTAssertEqual(reader.entries.count, original.entries.count)
        for (entry, previous) in zip(reader.entries, original.entries) {
            XCTAssertEqual(entry.kind, previous.kind, entry.name)
            let size = previous.kind == .symlink && (format == .tar || format == .tarGzip)
                ? 0 : previous.uncompressedSize
            XCTAssertEqual(entry.uncompressedSize, size, entry.name)
            XCTAssertEqual(entry.posixPermissions, previous.posixPermissions, entry.name)
            XCTAssertEqual(entry.modificationDate.map { floor($0.timeIntervalSince1970) },
                           previous.modificationDate.map { floor($0.timeIntervalSince1970) }, entry.name)
            let actual = try contents(entry, reader: reader)
            XCTAssertEqual(CRC32.checksum(actual), CRC32.checksum(expected[previous.index]), entry.name)
            XCTAssertEqual(actual, expected[previous.index], entry.name)
            XCTAssertFalse(entry.isEncrypted)
        }
        let seven = try run("7zz", ["t", output.path], in: directory)
        XCTAssertTrue(seven.contains("Everything is Ok"), seven)
        XCTAssertFalse(seven.contains("Headers Error"), seven)
        try run("bsdtar", ["-tf", output.path], in: directory)
        XCTAssertEqual(try workDirectories(in: directory), [])
    }

    func testZIPFixtureRewritesToZIP() throws { try verifyZIPFixture(to: .zip) }
    func testZIPFixtureRewritesToTAR() throws { try verifyZIPFixture(to: .tar) }
    func testZIPFixtureRewritesToTarGzip() throws { try verifyZIPFixture(to: .tarGzip) }
    func testZIPFixtureRewritesToSevenZip() throws { try verifyZIPFixture(to: .sevenZip) }
    func testZIPFixtureRewritesToLHA() throws { try verifyZIPFixture(to: .lha) }

    func testLHAOutputPassesLhasaWhenAvailable() throws {
        _ = try tool("lha")
        let directory = try directory("lhasa")
        let source = try archive(in: directory)
        let output = directory.appendingPathComponent("output.lha")
        try ArchiveRewriter.open(url: source, output: output, format: .lha).commit()
        try run("lha", ["t", output.path], in: directory)
    }

    func testRemoveRenameAndAddCarryOnlySurvivorsInIndexOrder() throws {
        let marker = Data("UNIQUE-REMOVED-ENTRY-PAYLOAD-73F174C7".utf8)
        for format in formats {
            let directory = try directory("edit-\(format)")
            let source = try archive(in: directory, filename: "source." + suffix(format), files: [
                ("removed.txt", marker), ("rename.txt", Data("renamed contents".utf8)),
                ("keep.txt", Data("keep".utf8)), ("parent/child.txt", Data("child".utf8))
            ])
            let originalNames = try ArchiveReader.open(url: source).entries.map(\.name)
            let rewriter = try ArchiveRewriter.open(url: source, format: format)
            try rewriter.remove(entriesAt: [0, 0])
            try rewriter.rename(entryAt: 1, to: "renamed.txt")
            try rewriter.add(data: Data("new removed path".utf8), as: "removed.txt")
            try rewriter.add(data: Data("new rename path".utf8), as: "rename.txt")
            try rewriter.addDirectory("new-empty")
            let disk = directory.appendingPathComponent("disk")
            try Data("disk contents".utf8).write(to: disk)
            try rewriter.add(contentsOf: disk, as: "disk.txt")
            XCTAssertEqual(rewriter.entryNames, originalNames)
            var done: [Int] = []
            try rewriter.commit { count, total in
                XCTAssertEqual(total, 3)
                done.append(count)
            }
            XCTAssertEqual(done, [1, 2, 3])
            let reader = try ArchiveReader.open(url: source)
            XCTAssertEqual(reader.entries.map(\.name), [
                "removed.txt", "rename.txt", "new-empty/", "disk.txt", "renamed.txt", "keep.txt", "parent/child.txt"
            ])
            XCTAssertEqual(try reader.read(reader.entries[4]), Data("renamed contents".utf8))
            XCTAssertEqual(rewriter.entryNames, originalNames)
            if format == .tar { XCTAssertNil(try Data(contentsOf: source).range(of: marker)) }
            XCTAssertEqual(try workDirectories(in: directory), [])
        }
    }

    func testConversionPreservesSourceSHA256() throws {
        let directory = try directory("conversion")
        let source = try archive(in: directory)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let output = directory.appendingPathComponent("output.7z")
        try ArchiveRewriter.open(url: source, output: output, format: .sevenZip).commit()
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), before)
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(reader.format, .sevenZip)
        XCTAssertEqual(reader.entries.count, 3)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("zeta contents".utf8))
    }

    private func encryptedZIP(in directory: URL) throws -> URL {
        let secret = directory.appendingPathComponent("secret.txt")
        try Data("encrypted contents\n".utf8).write(to: secret)
        let source = directory.appendingPathComponent("encrypted.zip")
        try run("zip", ["-q", "-P", "correct-password", "-j", source.path, secret.path], in: directory)
        XCTAssertTrue(try ArchiveReader.open(url: source).entries[0].isEncrypted)
        return source
    }

    private func assertInvalidState(_ rewriter: ArchiveRewriter, source: URL,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let operations: [() throws -> Void] = [
            { try rewriter.add(data: Data(), as: "later") },
            { try rewriter.add(contentsOf: source, as: "later") },
            { try rewriter.addDirectory("later") },
            { try rewriter.remove(entriesAt: []) },
            { try rewriter.rename(entryAt: 0, to: "later") },
            { try rewriter.commit() },
            { try rewriter.commit(didCarry: { _, _ in }) }
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation(), file: file, line: line) {
                XCTAssertEqual($0 as? RewriterError, .invalidState, file: file, line: line)
            }
        }
    }

    func testEncryptedZIPWithoutPasswordCleansUp() throws {
        for inPlace in [false, true] {
            let directory = try directory("no-password-\(inPlace)")
            let source = try encryptedZIP(in: directory)
            let before = try Data(contentsOf: source)
            let output = directory.appendingPathComponent("output.zip")
            let rewriter = try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: .zip)
            XCTAssertTrue(rewriter.hasEncryptedEntries)
            XCTAssertThrowsError(try rewriter.commit()) {
                XCTAssertEqual($0 as? RewriterError, .password(entry: "secret.txt"))
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try workDirectories(in: directory), [])
            assertInvalidState(rewriter, source: source)
        }
    }

    func testEncryptedZIPWrongPasswordCleansUp() throws {
        for inPlace in [false, true] {
            let directory = try directory("wrong-password-\(inPlace)")
            let source = try encryptedZIP(in: directory)
            let before = try Data(contentsOf: source)
            let output = directory.appendingPathComponent("output.tar")
            let rewriter = try ArchiveRewriter.open(url: source, password: "wrong-password",
                                                    output: inPlace ? nil : output, format: .tar)
            try rewriter.add(data: Data("queued".utf8), as: "queued")
            XCTAssertEqual(try workDirectories(in: directory).count, 1)
            XCTAssertThrowsError(try rewriter.commit()) {
                XCTAssertEqual($0 as? RewriterError, .password(entry: "secret.txt"))
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try workDirectories(in: directory), [])
            assertInvalidState(rewriter, source: source)
        }
    }

    func testEncryptedZIPCorrectPasswordWritesUnencryptedContents() throws {
        let directory = try directory("correct-password")
        let source = try encryptedZIP(in: directory)
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("output.zip")
        try ArchiveRewriter.open(url: source, password: "correct-password", output: output, format: .zip).commit()
        let reader = try ArchiveReader.open(url: output)
        XCTAssertFalse(reader.entries[0].isEncrypted)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("encrypted contents\n".utf8))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testEncryptedSevenZipHeadersRequirePasswordAtOpen() throws {
        let directory = try directory("encrypted-headers")
        let file = directory.appendingPathComponent("secret")
        try Data("header-encrypted contents".utf8).write(to: file)
        let source = directory.appendingPathComponent("encrypted.7z")
        try run("7zz", ["a", "-t7z", "-pcorrect-password", "-mhe=on", source.path, file.path], in: directory)
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("output.zip")
        for password: String? in [nil, "wrong-password"] {
            XCTAssertThrowsError(try ArchiveRewriter.open(url: source, password: password, output: output, format: .zip)) {
                XCTAssertEqual($0 as? RewriterError, .password(entry: nil))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try workDirectories(in: directory), [])
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
        try ArchiveRewriter.open(url: source, password: "correct-password", output: output, format: .zip).commit()
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("header-encrypted contents".utf8))
    }

    func testSolidSevenZipConvertsAllEntriesInIndexOrder() throws {
        let directory = try directory("solid")
        let files = ["zeta.txt", "alpha.txt", "middle.txt"]
        for name in files { try Data(repeating: UInt8(name.utf8.first!), count: 400_013).write(to: directory.appendingPathComponent(name)) }
        let source = directory.appendingPathComponent("solid.7z")
        try run("7zz", ["a", "-t7z", "-ms=on", source.path] + files, in: directory)
        let original = try ArchiveReader.open(url: source)
        XCTAssertEqual(original.entries.count, 3)
        XCTAssertEqual(Set(original.entries.map(\.solidGroup)).count, 1)
        XCTAssertNotEqual(original.entries[0].solidGroup, -1)
        let output = directory.appendingPathComponent("output.zip")
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .zip)
        try rewriter.rename(entryAt: 0, to: "renamed-first")
        try rewriter.commit()
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(reader.entries.map(\.name), ["renamed-first"] + original.entries.dropFirst().map(\.name))
        for (entry, previous) in zip(reader.entries, original.entries) {
            XCTAssertEqual(try reader.read(entry), try Data(contentsOf: directory.appendingPathComponent(previous.name)))
        }
        try run("7zz", ["t", output.path], in: directory)
    }

    func testCancellationOnSecondCarryRemovesOutputAndInvalidatesInstance() throws {
        for format in formats {
            for inPlace in [false, true] {
                let directory = try directory("cancel-\(format)-\(inPlace)")
                let source = try archive(in: directory)
                let before = try Data(contentsOf: source)
                let output = directory.appendingPathComponent("output")
                let rewriter = try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: format)
                try rewriter.add(data: Data("already written".utf8), as: "queued")
                var done: [Int] = []
                XCTAssertThrowsError(try rewriter.commit { count, total in
                    XCTAssertEqual(total, 3)
                    done.append(count)
                    if count == 2 { throw CancellationError() }
                }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
                XCTAssertEqual(done, [1, 2])
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try workDirectories(in: directory), [])
                assertInvalidState(rewriter, source: source)
            }
        }
    }

    func testDeinitWithoutCommitRemovesQueuedOutputAndWorkDirectory() throws {
        for format in formats {
            for inPlace in [false, true] {
                let directory = try directory("abandon-\(format)-\(inPlace)")
                let source = try archive(in: directory)
                let before = try Data(contentsOf: source)
                let output = directory.appendingPathComponent("output")
                var rewriter: ArchiveRewriter? = try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: format)
                try rewriter!.add(data: Data("discarded".utf8), as: "queued")
                XCTAssertEqual(try workDirectories(in: directory).count, 1)
                if !inPlace { XCTAssertTrue(FileManager.default.fileExists(atPath: output.path)) }
                rewriter = nil
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try workDirectories(in: directory), [])
            }
        }
    }

    func testCarryCallbackCannotMutateOrRecursivelyCommit() throws {
        let directory = try directory("callback-state")
        let source = try archive(in: directory)
        let output = directory.appendingPathComponent("output.zip")
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .zip)
        let names = rewriter.entryNames
        try rewriter.commit { done, _ in
            if done == 1 { self.assertInvalidState(rewriter, source: source) }
        }
        XCTAssertEqual(try ArchiveReader.open(url: output).entries.map(\.name), names)
        XCTAssertEqual(try workDirectories(in: directory), [])
    }

    private func assertUnrepresentable(_ source: URL, format: GyoshukuKit.ArchiveFormat, entry: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = source.deletingLastPathComponent()
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("refused-output")
        for inPlace in [false, true] {
            XCTAssertThrowsError(try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: format),
                                 file: file, line: line) { error in
                guard case let .unrepresentable(name, reason) = error as? RewriterError else {
                    return XCTFail("\(error)", file: file, line: line)
                }
                XCTAssertEqual(name, entry, file: file, line: line)
                XCTAssertFalse(reason.isEmpty, file: file, line: line)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
            XCTAssertEqual(try workDirectories(in: directory), [], file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: source), before, file: file, line: line)
        }
    }

    func testTarSymlinkIsUnrepresentableInLHAAtOpen() throws {
        let directory = try directory("unrepresentable-symlink")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path,
                                                  withDestinationPath: "target")
        let source = directory.appendingPathComponent("source.tar")
        try run("bsdtar", ["-cf", source.path, "link"], in: directory)
        try assertUnrepresentable(source, format: .lha, entry: "link")
    }

    func testColonNameIsUnrepresentableInZIPAtOpen() throws {
        let directory = try directory("unrepresentable-name")
        try Data("colon".utf8).write(to: directory.appendingPathComponent("a:b"))
        let source = directory.appendingPathComponent("source.tar")
        // -P がない bsdtar は a: を Windows drive letter と見なして削除する。
        try run("bsdtar", ["-P", "-cf", source.path, "a:b"], in: directory)
        XCTAssertEqual(try ArchiveReader.open(url: source).entries.map(\.name), ["a:b"])
        try assertUnrepresentable(source, format: .zip, entry: "a:b")
    }

    func testUnrepresentableNamesKindsHardLinksAndDatesAreRejectedBeforeOutput() throws {
        // 非対応の metadata は tar の header で作り、writer の公開 API に先に拒否されないようにする。
        let cases: [(String, TarRecords.Entry, GyoshukuKit.ArchiveFormat)] = [
            ("cp932", .init(name: Data("emoji-😀".utf8), mtime: 1_700_000_001), .lha),
            ("other", .init(name: Data("fifo".utf8), type: 0x36), .zip),
            ("hardlink", .init(name: Data("hard".utf8), type: 0x31, link: Data("missing".utf8)), .zip),
            ("zip-date", .init(name: Data("future".utf8), mtime: Int64(Int32.max) + 1), .zip),
            ("lha-date", .init(name: Data("past".utf8), mtime: -1), .lha),
            ("seven-date", .init(name: Data("ancient".utf8), mtime: -11_644_473_601), .sevenZip),
            ("empty-file", .init(name: Data("./".utf8)), .zip),
            ("empty-link", .init(name: Data(".".utf8), type: 0x32, link: Data("target".utf8)), .zip),
            ("dotdot", .init(name: Data("a/../b".utf8)), .zip),
            ("backslash", .init(name: Data("a\\b".utf8)), .zip)
        ]
        for (label, entry, format) in cases {
            let directory = try directory("unrepresentable-" + label)
            let source = directory.appendingPathComponent("source.tar")
            try (entry.headers() + Data(count: 1024)).write(to: source)
            try assertUnrepresentable(source, format: format, entry: String(decoding: entry.name, as: UTF8.self))
        }
    }

    private func appendToSource(_ source: URL) throws {
        let file = try FileHandle(forWritingTo: source)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("new source bytes".utf8))
    }

    private func assertInvalidArchive(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case .invalidArchive = $0 as? RewriterError else { return XCTFail("\($0)", file: file, line: line) }
        }
    }

    func testSourceModifiedBeforeCommitIsPreservedInBothModes() throws {
        for inPlace in [false, true] {
            for touch in [false, true] {
                let directory = try directory("changed-before-\(inPlace)-\(touch)")
                let source = try archive(in: directory)
                let output = directory.appendingPathComponent("output.zip")
                let rewriter = try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: .zip)
                try rewriter.addDirectory("queued")
                if touch {
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                         ofItemAtPath: source.path)
                } else { try appendToSource(source) }
                let changed = try Data(contentsOf: source)
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                assertInvalidArchive { try rewriter.commit() }
                XCTAssertEqual(try Data(contentsOf: source), changed)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
                               attributes[.modificationDate] as? Date)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try workDirectories(in: directory), [])
                assertInvalidState(rewriter, source: source)
            }
        }
    }

    func testSourceModifiedDuringCarryIsCheckedAgainBeforePublishInBothModes() throws {
        for inPlace in [false, true] {
            let directory = try directory("changed-during-\(inPlace)")
            let source = try archive(in: directory)
            let output = directory.appendingPathComponent("output.tar")
            let rewriter = try ArchiveRewriter.open(url: source, output: inPlace ? nil : output, format: .tar)
            var changed: Data?
            assertInvalidArchive {
                try rewriter.commit { done, total in
                    if done == total {
                        try self.appendToSource(source)
                        changed = try Data(contentsOf: source)
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), try XCTUnwrap(changed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try workDirectories(in: directory), [])
            assertInvalidState(rewriter, source: source)
        }
    }

    private func hardLinkArchive(in directory: URL) throws -> URL {
        let target = directory.appendingPathComponent("target")
        try Data(repeating: 0x37, count: 300_001).write(to: target)
        try FileManager.default.linkItem(at: target, to: directory.appendingPathComponent("hard"))
        let source = directory.appendingPathComponent("source.tar")
        try run("bsdtar", ["-cf", source.path, "target", "hard"], in: directory)
        let reader = try ArchiveReader.open(url: source)
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .hardlink])
        XCTAssertEqual(reader.entries[1].formatSpecific["hardLinkTargetIndex"], "0")
        return source
    }

    func testHardLinkKeepsRenamedTargetInTarOutputs() throws {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let directory = try directory("hardlink-kept-\(format)")
            let source = try hardLinkArchive(in: directory)
            let output = directory.appendingPathComponent("output." + suffix(format))
            let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format)
            try rewriter.rename(entryAt: 0, to: "renamed-target")
            try rewriter.commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map(\.kind), [.file, .hardlink])
            XCTAssertEqual(reader.entries[1].formatSpecific["linkPath"], "renamed-target")
            XCTAssertEqual(reader.entries[1].formatSpecific["hardLinkTargetIndex"], "0")
            try run("bsdtar", ["-tf", output.path], in: directory)
        }
    }

    func testHardLinkExpandsTargetContentsForNonTarOutputs() throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] {
            let directory = try directory("hardlink-expanded-\(format)")
            let source = try hardLinkArchive(in: directory)
            let output = directory.appendingPathComponent("output." + suffix(format))
            try ArchiveRewriter.open(url: source, output: output, format: format).commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map(\.name), ["target", "hard"])
            XCTAssertEqual(reader.entries.map(\.kind), [.file, .file])
            for entry in reader.entries { XCTAssertEqual(try reader.read(entry), Data(repeating: 0x37, count: 300_001)) }
            XCTAssertEqual(try workDirectories(in: directory), [])
        }
    }

    func testHardLinkExpandsRemovedTargetInsteadOfAnAddedReplacement() throws {
        for format in formats {
            let directory = try directory("hardlink-removed-\(format)")
            let source = try hardLinkArchive(in: directory)
            let output = directory.appendingPathComponent("output." + suffix(format))
            let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format)
            try rewriter.remove(entriesAt: [0])
            try rewriter.add(data: Data("replacement".utf8), as: "target")
            try rewriter.commit { done, total in XCTAssertEqual(done, 1); XCTAssertEqual(total, 1) }
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map(\.name), ["target", "hard"])
            XCTAssertEqual(reader.entries.map(\.kind), [.file, .file])
            guard reader.entries.count == 2 else { continue }
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("replacement".utf8))
            XCTAssertEqual(try reader.read(reader.entries[1]), Data(repeating: 0x37, count: 300_001))
            XCTAssertEqual(try workDirectories(in: directory), [])
        }
    }

    func testInPlaceRewriteRestoresModeAndQuarantine() throws {
        let directory = try directory("metadata")
        let source = try archive(in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let quarantine = Data("0081;6553f101;GyoshukuKit;01234567-89AB-CDEF-0123-456789ABCDEF".utf8)
        XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
        let rewriter = try ArchiveRewriter.open(url: source, format: .tar)
        try rewriter.rename(entryAt: 0, to: "renamed")
        try rewriter.commit()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var value = Data(count: 1024)
        let count = value.withUnsafeMutableBytes { getxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(count, quarantine.count)
        if count >= 0 { XCTAssertEqual(value.prefix(count), quarantine) }
        XCTAssertEqual(try ArchiveReader.open(url: source).entries[0].name, "renamed")
        XCTAssertEqual(try workDirectories(in: directory), [])
    }

    private func dotRootArchive(in directory: URL) throws -> URL {
        let tree = directory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("root child".utf8).write(to: tree.appendingPathComponent("file.txt"))
        try Data("nested child".utf8).write(to: tree.appendingPathComponent("nested/child.txt"))
        let source = directory.appendingPathComponent("source.tar")
        // cd tree && tar -cf ../source.tar . と同じ root record と ./ 接頭辞を作る。
        try run("bsdtar", ["-cf", source.path, "-C", tree.path, "."], in: directory)
        return source
    }

    func testDotPrefixedTarOmitsRootAndCarriesNormalizedNames() throws {
        let directory = try directory("dot-root")
        let source = try dotRootArchive(in: directory)
        let original = try ArchiveReader.open(url: source)
        XCTAssertEqual(original.entries[0].kind, .directory)
        XCTAssertEqual(original.entries[0].pathComponents, ["."])
        let output = directory.appendingPathComponent("output.zip")
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .zip)
        XCTAssertEqual(rewriter.entryNames, original.entries.map(\.name))
        var counts: [Int] = []
        try rewriter.commit { done, total in
            XCTAssertEqual(total, original.entries.count - 1)
            counts.append(done)
        }
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(Set(reader.entries.map(\.name)), Set(["file.txt", "nested/", "nested/child.txt"]))
        XCTAssertFalse(reader.entries.contains { $0.name.isEmpty || $0.name.hasPrefix("./") })
        XCTAssertEqual(counts, Array(1..<original.entries.count))
        let file = try XCTUnwrap(reader.entries.first { $0.name == "file.txt" })
        XCTAssertEqual(try reader.read(file), Data("root child".utf8))
        XCTAssertEqual(rewriter.entryNames, original.entries.map(\.name))
    }

    func testRootDirectoryIndexCanBeRemovedOrRenamedWithoutChangingChildren() throws {
        for remove in [false, true] {
            let directory = try directory("root-edit-\(remove)")
            let source = try dotRootArchive(in: directory)
            let output = directory.appendingPathComponent("output.zip")
            let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .zip)
            let names = rewriter.entryNames
            if remove { try rewriter.remove(entriesAt: [0, 0]) }
            else { try rewriter.rename(entryAt: 0, to: "explicit-root") }
            XCTAssertEqual(rewriter.entryNames, names)
            try rewriter.commit()
            let reader = try ArchiveReader.open(url: output)
            let expected = ["file.txt", "nested/", "nested/child.txt"] + (remove ? [] : ["explicit-root/"])
            XCTAssertEqual(Set(reader.entries.map(\.name)), Set(expected))
            if !remove { XCTAssertEqual(reader.entries[0].kind, .directory) }
        }
    }

    func testUnknownSizeSourceStreamsThroughTemporaryFile() throws {
        let directory = try directory("unknown-size")
        let source = directory.appendingPathComponent("payload.gz")
        let data = Data(repeating: 0x38, count: 800_123)
        var compressed = Data()
        try GzipCompressor(level: 6).write(data, finish: true) { compressed.append($0) }
        try compressed.write(to: source)
        let original = try ArchiveReader.open(url: source)
        XCTAssertNil(original.entries[0].uncompressedSize)
        let output = directory.appendingPathComponent("output.tar")
        let start = floor(Date().timeIntervalSince1970)
        try ArchiveRewriter.open(url: source, output: output, format: .tar).commit()
        let reader = try ArchiveReader.open(url: output)
        XCTAssertEqual(reader.entries[0].name, "payload")
        XCTAssertEqual(reader.entries[0].uncompressedSize, UInt64(data.count))
        XCTAssertEqual(reader.entries[0].posixPermissions, 0o644)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reader.entries[0].modificationDate).timeIntervalSince1970, start)
        XCTAssertEqual(try reader.read(reader.entries[0]), data)
        XCTAssertEqual(try workDirectories(in: directory), [])
    }

    func testOwnerIDsAreDroppedUnlessRequestedForTar() throws {
        let directory = try directory("owners")
        let source = directory.appendingPathComponent("source.tar")
        let entry = TarRecords.Entry(name: Data("owned".utf8), mtime: 1_700_000_001, uid: 501, gid: 20)
        try (entry.headers() + Data(count: 1024)).write(to: source)
        for preserve in [false, true] {
            let output = directory.appendingPathComponent("output-\(preserve).tar")
            try ArchiveRewriter.open(url: source, output: output, format: .tar,
                                     options: WriterOptions(preserveOwnerIDs: preserve)).commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries[0].formatSpecific["uid"], preserve ? "501" : "0")
            XCTAssertEqual(reader.entries[0].formatSpecific["gid"], preserve ? "20" : "0")
        }
    }

    func testCollisionsUsePostEditAndAppendedPathsInEveryFormat() throws {
        for format in formats {
            let directory = try directory("collisions-\(format)")
            let source = try archive(in: directory)
            let before = try Data(contentsOf: source)
            for path in ["added", "added/child", "nested"] {
                let rewriter = try ArchiveRewriter.open(url: source, format: format)
                try rewriter.add(data: Data("new".utf8), as: "added")
                XCTAssertThrowsError(try rewriter.rename(entryAt: 0, to: path))
                assertInvalidState(rewriter, source: source)
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertEqual(try workDirectories(in: directory), [])
            }
            let rewriter = try ArchiveRewriter.open(url: source, format: format)
            try rewriter.addDirectory("explicit")
            try rewriter.remove(entriesAt: [0])
            XCTAssertThrowsError(try rewriter.addDirectory("explicit")) {
                XCTAssertEqual($0 as? WriterError, .duplicatePath("explicit/"))
            }
            XCTAssertEqual(try workDirectories(in: directory), [])
        }
    }

    func testInvalidIndicesAndRemovedEntryRenamesInvalidateTheRewriter() throws {
        let directory = try directory("indices")
        let source = try archive(in: directory)
        let before = try Data(contentsOf: source)
        for index in [-1, 3, Int.max] {
            let remove = try ArchiveRewriter.open(url: source, format: .zip)
            XCTAssertThrowsError(try remove.remove(entriesAt: [0, index])) {
                XCTAssertEqual($0 as? UpdaterError, .invalidEntryIndex(index))
            }
            assertInvalidState(remove, source: source)
            let rename = try ArchiveRewriter.open(url: source, format: .zip)
            XCTAssertThrowsError(try rename.rename(entryAt: index, to: "valid")) {
                XCTAssertEqual($0 as? UpdaterError, .invalidEntryIndex(index))
            }
        }
        let removed = try ArchiveRewriter.open(url: source, format: .zip)
        try removed.remove(entriesAt: [0])
        XCTAssertThrowsError(try removed.rename(entryAt: 0, to: "removed")) {
            XCTAssertEqual($0 as? UpdaterError, .invalidEntryIndex(0))
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testRemovingDirectoryDoesNotRemoveOrSynthesizeChildren() throws {
        let directory = try directory("virtual-folders")
        let source = try archive(in: directory)
        let updater = try ArchiveUpdater.open(url: source)
        try updater.addDirectory("nested")
        try updater.commit()
        let rewriter = try ArchiveRewriter.open(url: source, format: .tar)
        let index = try XCTUnwrap(rewriter.entryNames.firstIndex(of: "nested/"))
        try rewriter.remove(entriesAt: [index])
        try rewriter.commit()
        XCTAssertEqual(try ArchiveReader.open(url: source).entries.map(\.name), ["zeta.txt", "nested/child.txt", "alpha.txt"])
    }

    func testExistingConversionOutputIsNeverOverwrittenOrRemoved() throws {
        let directory = try directory("exclusive-output")
        let source = try archive(in: directory)
        let output = directory.appendingPathComponent("existing")
        let original = Data("existing output".utf8)
        try original.write(to: output)
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .zip)
        XCTAssertThrowsError(try rewriter.commit()) {
            XCTAssertEqual($0 as? WriterError, .io(operation: "create", code: EEXIST))
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try workDirectories(in: directory), [])
    }

    func testCorruptArchiveAndPayloadMapToInvalidArchive() throws {
        let directory = try directory("corrupt")
        let bad = directory.appendingPathComponent("bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        assertInvalidArchive { _ = try ArchiveRewriter.open(url: bad, format: .zip) }
        let source = try archive(in: directory)
        var bytes = try Data(contentsOf: source)
        let records = try ZipUpdateLayout(source: ZipUpdateSource(url: source))
        // CD の CRC だけを壊す。open は metadata を読めるが carry の整合性検査で失敗する。
        bytes[Int(records.centralOffset) + 16] ^= 0xFF
        try bytes.write(to: source)
        let output = directory.appendingPathComponent("output.tar")
        let rewriter = try ArchiveRewriter.open(url: source, output: output, format: .tar)
        assertInvalidArchive { try rewriter.commit() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try workDirectories(in: directory), [])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testArchiveEditingProtocolAndSuccessfulCommitAreIdempotent() throws {
        for rewrite in [false, true] {
            let directory = try directory("protocol-\(rewrite)")
            let source = try archive(in: directory)
            let editor: any ArchiveEditing = try rewrite
                ? ArchiveRewriter.open(url: source, format: .tar) : ArchiveUpdater.open(url: source)
            XCTAssertEqual(editor.entryNames, ["zeta.txt", "nested/child.txt", "alpha.txt"])
            try editor.remove(entriesAt: [0])
            try editor.rename(entryAt: 1, to: "renamed")
            try editor.add(data: Data("new".utf8), as: "added", modificationDate: date, permissions: 0o600)
            try editor.addDirectory("empty")
            let disk = directory.appendingPathComponent("disk")
            try Data("disk".utf8).write(to: disk)
            try editor.add(contentsOf: disk, as: "disk")
            try editor.commit()
            let committed = try Data(contentsOf: source)
            try editor.commit()
            XCTAssertEqual(try Data(contentsOf: source), committed)
            XCTAssertEqual(Set(try ArchiveReader.open(url: source).entries.map(\.name)), Set(["renamed", "alpha.txt", "added", "empty/", "disk"]))
        }
    }
}
