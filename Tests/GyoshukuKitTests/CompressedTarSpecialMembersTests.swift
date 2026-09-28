import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

/// hard link・pax の global header・GNU sparse・二つの chunk にまたがる旧い終端・python / GNU / bsd tar が書いた入力を
/// 圧縮 tar のまま編集し、同じ編集を `TarUpdater` にかけた tar と照合する（照合は `CompressedTarTestSupport.edit`）。
// 旧名: CompressedTarP2OracleTests
final class CompressedTarSpecialMembersTests: XCTestCase {
    func testHardLinksGlobalSparseAndNameTransitions() throws {
        let root = try TestSupport.directory("compressed-tar-special-members")
        let raw = root.appendingPathComponent("special.tar")
        let comment = TarEditTestSupport.extensionBytes(0x67, TarRecords.paxRecord("comment", value: Data("keep me".utf8)))
        let map = Data("2\n0\n2\n8\n2\n".utf8)
        let payload = map + Data(count: 512 - map.count) + Data("abcd".utf8)
        let pax = [("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0"), ("GNU.sparse.realsize", "10"), ("GNU.sparse.name", "sparse")]
            .reduce(Data()) { $0 + TarRecords.paxRecord($1.0, value: Data($1.1.utf8)) }
        var bytes = comment
        for (name, link) in [("target", ""), ("link1", "target"), ("link2", "link1")] {
            let body = link.isEmpty ? Data("content".utf8) : Data()
            bytes += TarRecords.Entry(name: Data(name.utf8), size: UInt64(body.count), uid: 501, gid: 20,
                                      type: link.isEmpty ? 0x30 : 0x31, link: Data(link.utf8)).headers()
            bytes += body + Data(count: TarRecords.padding(UInt64(body.count)))
        }
        bytes += TarEditTestSupport.extensionBytes(0x78, pax)
        bytes += TarRecords.Entry(name: Data("GNUSparseFile.1/sparse".utf8), size: UInt64(payload.count)).headers()
        bytes += payload + Data(count: TarRecords.padding(UInt64(payload.count)))
        bytes += TarRecords.Entry(name: Data(("cafe\u{301}/" + String(repeating: "n", count: 140)).utf8)).headers()
        bytes += Data(count: 1024 + (10240 - (bytes.count + 1024) % 10240) % 10240)
        try bytes.write(to: raw)
        for format in CompressedTarTestSupport.formats {
            for aligned in [false, true] {
                let source = root.appendingPathComponent("\(format)-\(aligned)." + format.testFileExtension)
                try CompressedTarTestSupport.compress(raw, to: source, format: format, aligned: aligned)
                for force in [false, true] {
                    _ = try CompressedTarTestSupport.edit(source, format: format, output: root.appendingPathComponent("out-\(format)-\(aligned)-\(force)"), force: force) {
                        try $0.remove(entriesAt: [0])
                        try $0.rename(entryAt: 1, to: String(repeating: "h", count: 180))
                        try $0.rename(entryAt: 3, to: "renamed/sparse")
                        try $0.rename(entryAt: 4, to: "short")
                    }
                }
            }
        }
    }
    func testLegacyTerminatorStraddlesTwoChunks() throws {
        for (format, size) in zip(CompressedTarTestSupport.formats, [1_047_552, 4_499_456, 16_776_192]) {
            let root = try TestSupport.directory("compressed-tar-straddle-\(format)")
            let raw = root.appendingPathComponent("straddle.tar")
            let writer = try ArchiveWriter.create(url: raw, format: .tar)
            try writer.add(data: Data(repeating: 55, count: size), as: "file", modificationDate: TestSupport.date)
            try writer.finish()
            let source = root.appendingPathComponent("source." + format.testFileExtension)
            try CompressedTarTestSupport.compress(raw, to: source, format: format, aligned: false)
            let output = root.appendingPathComponent("out")
            _ = try CompressedTarTestSupport.edit(source, format: format, output: output) { try $0.rename(entryAt: 0, to: "name") }
            let snapshot = try CompressedTarTestSupport.open(output).tarEditingSnapshot()!
            XCTAssertEqual(snapshot.chunkMap?.chunks.last?.imageRange.lowerBound, snapshot.layout?.endOfArchiveOffset)
        }
    }
    func testPythonPaxGNUAndBSDArchives() throws {
        let root = try TestSupport.directory("compressed-tar-tool-inputs")
        let script = """
        import io,tarfile,sys
        with tarfile.open(sys.argv[1],'w',format=tarfile.PAX_FORMAT if sys.argv[2]=='pax' else tarfile.GNU_FORMAT) as t:
            for n in ['one','two','._two','cafe\\u0301/'+('n'*140)]:
                i=tarfile.TarInfo(n); i.size=7; i.uid=501; i.gid=20; i.uname='alice'; i.mtime=1700000001
                if sys.argv[2]=='pax': i.pax_headers={'LIBARCHIVE.xattr.user.test':'dmFsdWU='}
                t.addfile(i,io.BytesIO(b'content'))
        """
        for variant in ["pax", "gnu", "bsd"] {
            let raw = root.appendingPathComponent("\(variant).tar")
            if variant == "bsd" {
                let files = try TestSupport.work(in: root)
                for name in ["one", "two", "._two"] { try Data("content".utf8).write(to: files.appendingPathComponent(name)) }
                try TestSupport.run(ReferenceTool.bsdtar, ["--format=pax", "--uid", "501", "--uname", "alice", "-cf", raw.path,
                                                       "-C", files.path, "one", "two", "._two"], in: root, log: "bsd")
            } else { try TestSupport.run(ReferenceTool.python3, ["-c", script, raw.path, variant], in: root, log: variant) }
            for format in CompressedTarTestSupport.formats {
                let source = root.appendingPathComponent("\(variant)." + format.testFileExtension)
                try CompressedTarTestSupport.compress(raw, to: source, format: format, aligned: false)
                _ = try CompressedTarTestSupport.edit(source, format: format, output: root.appendingPathComponent("out-\(variant)-\(format)")) {
                    try $0.remove(entriesAt: [0]); try $0.rename(entryAt: 1, to: String(repeating: "a", count: 180))
                }
            }
        }
    }
}
