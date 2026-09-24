import Darwin
import Foundation
import KaitoKit
import XCTest
import GyoshukuKit

final class ArchiveRewriterVolumeSetTests: XCTestCase {
    private let formats: [(GyoshukuKit.ArchiveFormat, String)] = [(.sevenZip, "7z"), (.tar, "tar")]

    private func archive(_ label: String, format: GyoshukuKit.ArchiveFormat, suffix: String) throws -> URL {
        let directory = try ZipTestSupport.directory("rewriter-volumes-\(label)-\(suffix)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source." + suffix)
        let writer = try ArchiveWriter.create(url: url, format: format)
        try writer.add(data: Data(repeating: 0x61, count: 8_192), as: "payload.bin",
                       modificationDate: ZipTestSupport.date)
        try writer.finish()
        return url
    }

    func testVolumeSetMatchesOpenedSplitVolumes() throws {
        for (format, suffix) in formats {
            let source = try archive("split", format: format, suffix: suffix)
            let data = try Data(contentsOf: source)
            let size = (data.count + 2) / 3
            var volumes: [URL] = []
            // writer の出力を形式に依存しないバイト分割で 3 巻にする。
            for index in 0..<3 {
                let url = source.appendingPathExtension(String(format: "%03d", index + 1))
                try data.subdata(in: (index * size)..<min((index + 1) * size, data.count)).write(to: url)
                volumes.append(url)
            }

            let rewriter = try ArchiveRewriter.open(url: volumes[0], format: format)
            let set = try XCTUnwrap(rewriter.volumeSet)
            XCTAssertEqual(rewriter.entryNames, ["payload.bin"])
            XCTAssertEqual(set.scheme, .numbered(stem: source.lastPathComponent, width: 3))
            XCTAssertEqual(set.openedVolumeIndex, 0)
            XCTAssertEqual(set.volumes.count, 3)
            XCTAssertEqual(set.volumes.map(\.url), volumes.map(\.standardizedFileURL))
            for (volume, url) in zip(set.volumes, volumes) {
                var info = stat()
                XCTAssertEqual(lstat(url.path, &info), 0)
                XCTAssertEqual(volume.inode, UInt64(info.st_ino))
                XCTAssertEqual(volume.device, UInt64(UInt32(bitPattern: info.st_dev)))
                XCTAssertEqual(volume.length, UInt64(info.st_size))
            }
        }
    }

    func testVolumeSetIsNilForSingleFile() throws {
        for (format, suffix) in formats {
            let source = try archive("single", format: format, suffix: suffix)
            let numbered = source.appendingPathExtension("001")
            try Data(contentsOf: source).write(to: numbered)
            // 兄弟巻のない .001 も単一ファイルとして扱う。
            for url in [source, numbered] {
                let rewriter = try ArchiveRewriter.open(url: url, format: format)
                XCTAssertEqual(rewriter.entryNames, ["payload.bin"])
                XCTAssertNil(rewriter.volumeSet)
            }
        }
    }
}
