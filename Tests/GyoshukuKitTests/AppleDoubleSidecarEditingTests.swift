import CryptoKit
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest

final class AppleDoubleSidecarEditingTests: XCTestCase {
    private func fixture(_ name: String, label: String) throws -> URL {
        let encoded = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/appledouble/\(name).b64")
        let data = try XCTUnwrap(Data(base64Encoded: try String(contentsOf: encoded, encoding: .utf8),
                                      options: .ignoreUnknownCharacters))
        let directory = try ZipTestSupport.directory("appledouble-\(label)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func exposedReader(_ url: URL) throws -> ArchiveReader {
        try ArchiveReader.open(url: url, options: ReaderOptions(appleDoublePolicy: .expose))
    }

    private func payloadHashes(_ reader: ArchiveReader) throws -> [String: Data] {
        var hashes: [String: Data] = [:]
        for entry in reader.entries where entry.kind == .file {
            hashes[entry.name] = Data(SHA256.hash(data: try reader.read(entry)))
        }
        return hashes
    }

    private func assertStoredZIPNames(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(names.count, 12, file: file, line: line)
        for name in ["folder/", "folder/rsrc.txt", "folder/plain.txt", "__MACOSX/",
                     "__MACOSX/folder/._rsrc.txt", "__MACOSX/folder/._plain.txt",
                     "__MACOSX/folder/._sub", "__MACOSX/folder/sub/._deep.txt"] {
            XCTAssertTrue(names.contains(name), name, file: file, line: line)
        }
        XCTAssertFalse(names.contains { $0.contains("..namedfork") }, file: file, line: line)
    }

    func testFinderZIPUpdaterPreservesSidecarsAcrossRemoveAndAdd() throws {
        let url = try fixture("finder.zip", label: "zip-remove-then-add")
        let original = try exposedReader(url)
        let originalNames = original.entries.map(\.name)
        var expectedHashes = try payloadHashes(original)
        let updater = try ArchiveUpdater.open(url: url)
        assertStoredZIPNames(updater.entryNames)
        assertStoredZIPNames(originalNames)
        XCTAssertEqual(updater.entryNames, originalNames)
        XCTAssertEqual(original.entries.map(\.index), Array(original.entries.indices))

        let index = try XCTUnwrap(updater.entryNames.firstIndex(of: "folder/plain.txt"))
        XCTAssertEqual(original.entries[index].name, "folder/plain.txt")
        try updater.remove(entriesAt: [index])
        try updater.commit()
        let remainingNames = originalNames.filter { $0 != "folder/plain.txt" }
        expectedHashes.removeValue(forKey: "folder/plain.txt")
        let removed = try exposedReader(url)
        XCTAssertEqual(removed.entries.map(\.name), remainingNames)
        XCTAssertEqual(try payloadHashes(removed), expectedHashes)

        let addition = Data("added after removal\n".utf8)
        let reopened = try ArchiveUpdater.open(url: url)
        XCTAssertEqual(reopened.entryNames, remainingNames)
        try reopened.add(data: addition, as: "added.txt")
        try reopened.commit()
        let result = try exposedReader(url)
        XCTAssertEqual(result.entries.map(\.name), remainingNames + ["added.txt"])
        XCTAssertFalse(result.entries.contains { $0.name.contains("..namedfork") })
        expectedHashes["added.txt"] = Data(SHA256.hash(data: addition))
        XCTAssertEqual(try payloadHashes(result), expectedHashes)
        let verification = try ZipTestSupport.run("/usr/bin/unzip", ["-t", url.path],
            in: url.deletingLastPathComponent(), log: "unzip-t")
        XCTAssertTrue(verification.contains("No errors detected"), verification)
    }

    func testFinderZIPUpdaterPreservesSidecarsWhenRemovingAndAddingTogether() throws {
        let url = try fixture("finder.zip", label: "zip-remove-and-add")
        let original = try exposedReader(url)
        var expectedHashes = try payloadHashes(original)
        let updater = try ArchiveUpdater.open(url: url)
        assertStoredZIPNames(updater.entryNames)
        let index = try XCTUnwrap(updater.entryNames.firstIndex(of: "folder/plain.txt"))
        try updater.remove(entriesAt: [index])
        let addition = Data("added in the same commit\n".utf8)
        try updater.add(data: addition, as: "added.txt")
        // 削除と追加を同じ commit に含め、追加後の staged reader でも元の index を使う。
        try updater.commit()

        let result = try exposedReader(url)
        XCTAssertEqual(result.entries.map(\.name),
                       original.entries.map(\.name).filter { $0 != "folder/plain.txt" } + ["added.txt"])
        XCTAssertFalse(result.entries.contains { $0.name.contains("..namedfork") })
        expectedHashes.removeValue(forKey: "folder/plain.txt")
        expectedHashes["added.txt"] = Data(SHA256.hash(data: addition))
        XCTAssertEqual(try payloadHashes(result), expectedHashes)
        let verification = try ZipTestSupport.run("/usr/bin/unzip", ["-t", url.path],
            in: url.deletingLastPathComponent(), log: "unzip-t")
        XCTAssertTrue(verification.contains("No errors detected"), verification)
    }

    func testMacTARRewriterPreservesSidecarNamesAndPayloadHashes() throws {
        let url = try fixture("mac.tar", label: "tar-rewrite")
        let original = try exposedReader(url)
        let originalNames = original.entries.map(\.name)
        let expectedHashes = try payloadHashes(original)
        XCTAssertEqual(originalNames.count, 10)
        for name in ["._folder", "folder/._rsrc.txt", "folder/._plain.txt",
                     "folder/._sub", "folder/sub/._deep.txt"] {
            XCTAssertTrue(originalNames.contains(name), name)
            XCTAssertNotNil(expectedHashes[name], name)
        }
        let output = url.deletingLastPathComponent().appendingPathComponent("rewritten.tar")
        let rewriter = try ArchiveRewriter.open(url: url, output: output, format: .tar)
        XCTAssertEqual(rewriter.entryNames, originalNames)
        XCTAssertFalse(rewriter.entryNames.contains { $0.contains("..namedfork") })
        try rewriter.commit()

        let result = try exposedReader(output)
        XCTAssertEqual(result.entries.map(\.name), originalNames)
        XCTAssertFalse(result.entries.contains { $0.name.contains("..namedfork") })
        XCTAssertEqual(try payloadHashes(result), expectedHashes)
    }

    func testRewriterProbeRefusesMergedResourceForkEntries() throws {
        for name in ["finder.zip", "mac.tar"] {
            let url = try fixture(name, label: "probe-\(name)")
            // 既定の .merge が作る擬似 entry を、外部 reader の一覧として渡す。
            let merged = try ArchiveReader.open(url: url)
            let fork = try XCTUnwrap(merged.entries.first { $0.formatSpecific["fork"] == "resource" })
            XCTAssertTrue(fork.name.contains("..namedfork"))
            XCTAssertThrowsError(try ArchiveRewriter.probe(entries: merged.entries, format: .zip)) {
                XCTAssertEqual($0 as? RewriterError, .unrepresentable(entry: fork.name,
                    reason: "resource fork の擬似 entry は書き込めません。reader を appleDoublePolicy .expose で開いてください"))
            }
            XCTAssertNoThrow(try ArchiveRewriter.probe(entries: exposedReader(url).entries, format: .zip))
        }
    }
}
