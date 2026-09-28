import Foundation
import Darwin
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class TarUpdaterInteropTests: XCTestCase {
    func testRealGitArchiveCommentIsPreserved() throws {
        guard let repository = ProcessInfo.processInfo.environment["GYOSHUKU_TAR_GIT_REPO"] else {
            throw XCTSkip("GYOSHUKU_TAR_GIT_REPO is not set")
        }
        let root = try TestSupport.directory("p2-git-archive")
        let source = root.appendingPathComponent("source.tar")
        try TestSupport.run(ReferenceTool.git, ["-C", repository, "archive", "--format=tar", "-o", source.path,
                                               "9fb6ee2", "Sources/GyoshukuKit"], in: root, log: "git-archive")
        let (layout, data, reader) = try TarEditTestSupport.scan(source)
        let first = try XCTUnwrap(layout.units.first)
        XCTAssertTrue(first.isGlobal)
        let output = root.appendingPathComponent("out.tar")
        let updater = try TarUpdater.open(url: source, output: output)
        let files = reader.entries.filter { $0.kind == .file }
        try updater.remove(entriesAt: [files[0].index])
        try updater.rename(entryAt: files[1].index, to: "renamed.swift")
        try updater.add(data: Data([1]), as: "added")
        try updater.commit()
        let result = try ZipUpdateSource(url: output)
        XCTAssertEqual(try data.bytes(at: 0, count: Int(first.paddedEnd)), try result.bytes(at: 0, count: Int(first.paddedEnd)))
        try TestSupport.run(ReferenceTool.bsdtar, ["-tvf", output.path], in: root, log: "git-list")
    }

    func testBSDAndPythonArchivesPreserveMetadataAcrossEdits() throws {
        let root = try TestSupport.directory("p2-interop")
        let disk = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: false)
        for name in ["one", "two", "three"] { try Data((name + "-payload").utf8).write(to: disk.appendingPathComponent(name)) }
        let value = Data("value".utf8)
        _ = value.withUnsafeBytes { setxattr(disk.appendingPathComponent("two").path, "com.example.gyoshuku", $0.baseAddress, $0.count, 0, 0) }
        for variant in ["bsd", "pax", "gnu", "ustar"] {
            let source = root.appendingPathComponent("\(variant).tar")
            if variant == "bsd" {
                try TestSupport.run(ReferenceTool.bsdtar, ["--format=pax", "-cf", source.path, "-C", disk.path, "one", "two", "three"], in: root, log: "create-bsd")
            } else {
                let script = """
                import tarfile,sys
                with tarfile.open(sys.argv[1],'w',format={'pax':tarfile.PAX_FORMAT,'gnu':tarfile.GNU_FORMAT,'ustar':tarfile.USTAR_FORMAT}[sys.argv[2]]) as t:
                    for n in ['one','two','three']: t.add(sys.argv[3]+'/'+n,arcname=n)
                """
                try TestSupport.run(ReferenceTool.python3, ["-c", script, source.path, variant, disk.path], in: root, log: "create-\(variant)")
            }
            let original = try ArchiveReader.open(url: source, options: .init(appleDoublePolicy: .expose))
            let output = root.appendingPathComponent("out-\(variant).tar")
            let renamed = variant == "gnu" ? "renamed-" + String(repeating: "n", count: 140) : "renamed"
            let updater = try TarUpdater.open(url: source, output: output)
            try updater.remove(entriesAt: [XCTUnwrap(original.entries.first { $0.name == "one" }).index])
            try updater.rename(entryAt: XCTUnwrap(original.entries.first { $0.name == "three" }).index, to: renamed)
            try updater.add(data: Data("added".utf8), as: "added", modificationDate: TestSupport.date)
            try updater.commit()
            let reader = try ArchiveReader.open(url: output, options: .init(appleDoublePolicy: .expose))
            let listing = try TestSupport.run(ReferenceTool.bsdtar, ["-tf", output.path], in: root, log: "list-\(variant)")
            // bsdtar は AppleDouble を metadata として処理する。
            for name in ["two", renamed, "added"] { XCTAssertTrue(listing.contains(name + "\n")) }
            try TestSupport.run(ReferenceTool.bsdtar, ["-tvf", output.path], in: root, log: "verbose-\(variant)")
            if FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip) {
                try TestSupport.run(ReferenceTool.sevenZip, ["t", output.path], in: root, log: "7zz-test-\(variant)")
                try TestSupport.run(ReferenceTool.sevenZip, ["l", output.path], in: root, log: "7zz-list-\(variant)")
            }
            let python = """
            import tarfile,sys,hashlib
            with tarfile.open(sys.argv[1]) as a, tarfile.open(sys.argv[2]) as b:
                x,y=a.getmember('two'),b.getmember('two')
                for k in ['size','uid','gid','uname','gname','linkname','pax_headers']: assert getattr(x,k)==getattr(y,k),(k,getattr(x,k),getattr(y,k))
                assert hashlib.sha256(a.extractfile(x).read()).digest()==hashlib.sha256(b.extractfile(y).read()).digest()
                assert b.extractfile(sys.argv[3]).read()==b'three-payload'
                assert b.extractfile('added').read()==b'added'
            """
            try TestSupport.run(ReferenceTool.python3, ["-c", python, source.path, output.path, renamed], in: root, log: "python-\(variant)")
            for tool in ["/opt/homebrew/bin/gtar", "/opt/homebrew/bin/gnutar"] where FileManager.default.isExecutableFile(atPath: tool) {
                // GNU tar は libarchive の xattr の pax keyword を知らず、警告を出力に混ぜる。
                try TestSupport.run(tool, ["--warning=no-unknown-keyword", "-tvf", output.path], in: root, log: "gnu-\(variant)")
                XCTAssertEqual(try TestSupport.run(tool, ["--warning=no-unknown-keyword", "-xOf", output.path, "two"], in: root,
                                                      log: "gnu-content-\(variant)"), "two-payload")
            }
            for entry in reader.entries where ["two", renamed, "added"].contains(entry.name) {
                let content = try TestSupport.run(ReferenceTool.bsdtar, ["-xOf", output.path, entry.name], in: root, log: "content-\(variant)-\(entry.name)")
                XCTAssertEqual(Data(content.utf8), try reader.read(entry))
            }
        }
    }
}
