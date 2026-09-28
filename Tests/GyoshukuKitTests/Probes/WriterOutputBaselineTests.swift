import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

/// 全形式の writer・rewriter と ZIP の updater の出力を `GYOSHUKU_P2_COMPAT_OUTPUT` へ書き出し、
/// `GYOSHUKU_P2_COMPAT_BASELINE` があれば別の build が書いた同名の file と byte 単位で比べる。
// 旧名: ArchiveWriterP2CompatibilityTests
final class WriterOutputBaselineTests: XCTestCase {
    func testCommittedG1ByteCompatibility() throws {
        let root = try OptInGate.path("GYOSHUKU_P2_COMPAT_OUTPUT")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1700000001)
        let disk = root.appendingPathComponent("disk")
        try Data("disk payload".utf8).write(to: disk)
        _ = chmod(disk.path, 0o640)
        var times = [timeval(tv_sec: 1700000001, tv_usec: 0), timeval(tv_sec: 1700000001, tv_usec: 0)]
        _ = utimes(disk.path, &times)
        let source = root.appendingPathComponent("source.tar")
        let entry = TarRecords.Entry(name: Data("owned".utf8), size: 7, mtime: 1700000001, uid: 501, gid: 20)
        try (entry.headers() + Data("payload".utf8) + Data(count: 505 + 1024)).write(to: source)
        let formats: [(ArchiveFormat, String)] = [(.zip, "zip"), (.tar, "tar"), (.tarGzip, "tar.gz"),
                                                 (.tarBzip2, "tar.bz2"), (.tarXZ, "tar.xz"), (.sevenZip, "7z"), (.lha, "lha")]
        var outputs: [String] = []
        for (format, suffix) in formats {
            let created = "create." + suffix
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent(created), format: format, options: .init(compressionThreads: 1))
            try writer.add(data: Data(repeating: 77, count: 12345), as: "data", modificationDate: date)
            _ = utimes(disk.path, &times)
            try writer.add(contentsOf: disk, as: "disk")
            try writer.finish()
            outputs.append(created)
            for preserve in [false, true] where !preserve || format.isTar || format == .zip {
                let name = "rewrite-\(preserve)." + suffix
                #if P2_G_BASELINE
                let options = WriterOptions(preserveOwnerIDs: preserve, compressionThreads: 1)
                #else
                let options = WriterOptions(preserveOwnerIDs: preserve, compressionThreads: 1,
                                            additionPlacement: .beginning, carriedTarOwnerIDs: preserve ? .keep : .reset)
                #endif
                let editor = try ArchiveRewriter.open(url: source, output: root.appendingPathComponent(name), format: format, options: options)
                try editor.rename(entryAt: 0, to: "renamed")
                try editor.add(data: Data([1, 2, 3]), as: "first", modificationDate: date)
                _ = utimes(disk.path, &times)
                try editor.add(contentsOf: disk, as: "disk")
                try editor.commit()
                outputs.append(name)
            }
        }
        let zipOutput = root.appendingPathComponent("update.zip")
        let updater = try ArchiveUpdater.open(url: root.appendingPathComponent("create.zip"), output: zipOutput)
        try updater.rename(entryAt: 0, to: "renamed")
        try updater.add(data: Data([4, 5]), as: "new", modificationDate: date)
        try updater.commit()
        outputs.append("update.zip")
        if let baseline = OptInGate.value("GYOSHUKU_P2_COMPAT_BASELINE") {
            for name in outputs {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)),
                               try Data(contentsOf: URL(fileURLWithPath: baseline).appendingPathComponent(name)), name)
            }
        }
        TestSupport.report("TAR-COMPAT files=\(outputs.count)")
    }
}
