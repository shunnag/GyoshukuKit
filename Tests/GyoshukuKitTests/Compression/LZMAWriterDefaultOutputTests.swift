import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

/// レベル追加前に固定した Apple 経路の書庫。fixture は再生成しない。
final class LZMAWriterDefaultOutputTests: XCTestCase {
    func testNilLevelMatchesFrozenArchives() throws {
        // ZIP の DOS timestamp はローカル時刻なので、fixture 生成時の JST に揃える。
        let originalZone = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Tokyo", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let originalZone { setenv("TZ", originalZone, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let directory = try TestSupport.directory("lzma-writer-default")
        for (format, suffix) in [(ArchiveFormat.tarXZ, "tar.xz"), (.sevenZip, "7z"), (.zip, "zip")] {
            for threads in [1, 4] {
                let url = directory.appendingPathComponent("\(threads).\(suffix)")
                let writer = try ArchiveWriter.create(url: url, format: format,
                    options: .init(compressionMethod: .xz, lzmaExtreme: threads == 4,
                        useCompressionHeuristic: false, compressionThreads: threads))
                try writer.add(data: LZMAEncoderCorpus.text(size: 192 << 10), as: "text.txt", modificationDate: TestSupport.date)
                try writer.add(data: Data(repeating: 0x5A, count: 17 << 20), as: "large.bin", modificationDate: TestSupport.date)
                try writer.add(data: Data(), as: "empty", modificationDate: TestSupport.date)
                try writer.finish()
                let frozen = TestPaths.fixtures.appendingPathComponent("lzma-writers/default.\(suffix)")
                XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: frozen), suffix)
            }
        }
    }
}
