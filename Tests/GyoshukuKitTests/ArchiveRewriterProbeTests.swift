import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

/// `ArchiveRewriter.probe(entries:format:)` は `open` と同じ表現可能性の判定を、書庫を開かずに行う。
/// 既存の fixture で open の受理・拒否と `unrepresentable` の内容が一致することを oracle にする。
final class ArchiveRewriterProbeTests: XCTestCase {
    private func fixture(_ names: [String], directoryIndices: Set<Int> = []) throws -> URL {
        let directory = try ZipTestSupport.directory("rewriter-probe-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.zip")
        let script = #"""
        import sys,zipfile,warnings
        warnings.simplefilter('ignore', UserWarning)
        directories=set(map(int,filter(None,sys.argv[2].split(','))))
        with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_STORED) as z:
            for i,name in enumerate(sys.argv[3:]):
                info=zipfile.ZipInfo(name,(2023,11,14,22,13,20)); info.create_system=3
                info.external_attr=((0o40755 if i in directories else 0o100644)<<16)|(0x10 if i in directories else 0)
                z.writestr(info,b'' if i in directories else ('payload-%d'%i).encode())
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path,
            directoryIndices.sorted().map(String.init).joined(separator: ",")] + names,
            in: directory, log: "create")
        return url
    }

    private func outcome(_ body: () throws -> Void) -> String {
        do { try body(); return "accepted" }
        catch let RewriterError.unrepresentable(entry, reason) { return "unrepresentable(\(entry)): \(reason)" }
        catch { return "other: \(error)" }
    }

    private func assertProbeMatchesOpen(_ url: URL, format: GyoshukuKit.ArchiveFormat,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try ArchiveReader.open(url: url).entries
        let opened = outcome { _ = try ArchiveRewriter.open(url: url, output: nil, format: format) }
        let probed = outcome { try ArchiveRewriter.probe(entries: entries, format: format) }
        XCTAssertEqual(probed, opened, "probe must give open's verdict for \(format)", file: file, line: line)
    }

    func testProbeMatchesOpenForCollisionsAndAcceptedShapes() throws {
        for names in [["a.txt", "a.txt"], ["caf\u{e9}.txt", "cafe\u{301}.txt"], ["parent", "parent/child"],
                      ["parent/child", "parent"], ["docs/readme.txt", "docs/notes.txt"]] {
            let url = try fixture(names)
            for format in [GyoshukuKit.ArchiveFormat.zip, .tar, .tarGzip, .sevenZip, .lha] {
                try assertProbeMatchesOpen(url, format: format)
            }
        }
        let directories = try fixture(["folder", "folder/"], directoryIndices: [0, 1])
        try assertProbeMatchesOpen(directories, format: .zip)
        let roots = try fixture(["./", ".", "folder/child", "folder/"], directoryIndices: [0, 1, 3])
        try assertProbeMatchesOpen(roots, format: .zip)
        XCTAssertEqual(outcome { try ArchiveRewriter.probe(entries: try ArchiveReader.open(url: roots).entries, format: .zip) },
                       "accepted")
    }

    func testProbeRefusesSymlinkForLHAAndOtherKindsWithoutOpeningAnything() throws {
        func entry(_ index: Int, name: String, kind: EntryKind, extra: [String: String] = [:]) -> ArchiveEntry {
            ArchiveEntry(index: index, rawName: RawName(bytes: Array(name.utf8)), name: name,
                         pathComponents: name.split(separator: "/").map(String.init), kind: kind,
                         uncompressedSize: 1, compressedSize: 1, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         posixPermissions: nil, isEncrypted: false, solidGroup: -1, crc32: nil,
                         methodDescription: "stored", formatSpecific: extra)
        }
        let link = [entry(0, name: "target.txt", kind: .file), entry(1, name: "link", kind: .symlink)]
        XCTAssertEqual(outcome { try ArchiveRewriter.probe(entries: link, format: .lha) },
                       "unrepresentable(link): LHA は symlink を保存できません")
        XCTAssertEqual(outcome { try ArchiveRewriter.probe(entries: link, format: .tar) }, "accepted")
        let other = [entry(0, name: "device", kind: .other)]
        XCTAssertEqual(outcome { try ArchiveRewriter.probe(entries: other, format: .zip) },
                       "unrepresentable(device): この entry 種別は書き込めません")
        let danglingHardLink = [entry(0, name: "copy", kind: .hardlink, extra: ["hardLinkTargetIndex": "5"])]
        XCTAssertEqual(outcome { try ArchiveRewriter.probe(entries: danglingHardLink, format: .tar) },
                       "unrepresentable(copy): hard link の参照先が欠けているか、先行する通常ファイルではありません")
    }
}
