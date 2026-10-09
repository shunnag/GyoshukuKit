import Darwin
import Foundation
import XCTest
@testable import GyoshukuKit

/// speed2/integrate 3b74afb の出力を固定し、既定設定の byte を守る。
final class SpeedPriorityDefaultOutputTests: XCTestCase {
    static var configurations: [(String, ArchiveFormat, WriterOptions)] {
        var result: [(String, ArchiveFormat, WriterOptions)] = []
        for level: Int? in [nil, 0] {
            let tag = level.map(String.init) ?? "apple"
            result += [("zip-xz-\(tag).zip", .zip, .init(compressionMethod: .xz, lzmaLevel: level)),
                       ("seven-\(tag).7z", .sevenZip, .init(lzmaLevel: level)),
                       ("solid-\(tag).7z", .sevenZip, .init(sevenZipSolid: .on(), lzmaLevel: level)),
                       ("tar-\(tag).tar.xz", .tarXZ, .init(lzmaLevel: level))]
        }
        result.append(("zip-zstd.zip", .zip, .init(compressionMethod: .zstd)))
        result.append(("tar.tar.lz", .tarLzip, .init(lzmaLevel: 0)))
        for method: SevenZipCompressionMethod in [.lzma, .ppmd, .bzip2, .deflate] {
            result.append(("solid-\(method).7z", .sevenZip, .init(sevenZipMethod: method, sevenZipSolid: .on(), lzmaLevel: 0)))
        }
        return result
    }

    // 辞書を越える二項目と既存の16 MiB片境界を含める。
    static let medium = Data(repeating: 0x41, count: 10 << 20)
    static let large = Data(repeating: 0x5A, count: (17 << 20) + 17)

    func testDefaultMatchesBaseCommit() throws {
        let previous = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Tokyo", 1); NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let directory = try TestSupport.directory("speed-priority-default")
        let frozen = TestPaths.fixtures.appendingPathComponent("speed-priority")
        let recording = OptInGate.value("GYOSHUKU_SPEED_RECORD_BASELINE").map { URL(fileURLWithPath: $0) }
        if let recording { try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true) }
        func verify(_ url: URL) throws {
            let bytes = try Data(contentsOf: url)
            if let recording { try bytes.write(to: recording.appendingPathComponent(url.lastPathComponent)) }
            else { XCTAssertEqual(bytes, try Data(contentsOf: frozen.appendingPathComponent(url.lastPathComponent)), url.lastPathComponent) }
        }
        for (name, format, base) in Self.configurations {
            var options = base
            options.compressionThreads = 1; options.useCompressionHeuristic = false
            let url = directory.appendingPathComponent(name)
            let writer = try ArchiveWriter.create(url: url, format: format, options: options)
            try writer.add(data: Self.medium, as: "medium", modificationDate: TestSupport.date)
            try writer.add(data: Self.large, as: "large", modificationDate: TestSupport.date)
            try writer.add(data: Self.medium, as: "last", modificationDate: TestSupport.date)
            try writer.finish()
            try verify(url)
        }
        let source = directory.appendingPathComponent("source.raw")
        try Self.large.write(to: source)
        for (name, format, options): (String, SingleStreamFormat, WriterOptions) in [
            ("single-apple.xz", .xz, .init(compressionThreads: 1)),
            ("single-0.xz", .xz, .init(lzmaLevel: 0, compressionThreads: 1)),
            ("single.lz", .lzip, .init(lzmaLevel: 0, compressionThreads: 1))
        ] {
            let url = directory.appendingPathComponent(name)
            try SingleStreamCompressor.compress(file: source, to: url, format: format, options: options)
            try verify(url)
        }
    }
}
