import Darwin
import Foundation
import CryptoKit
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

    // 2026-10-29: .avif の既定出力を意図的に変更。従来のgoldenは上で保持し、opt-outも別に固定する。
    func testCompressedContentDefaultAndOptOutGoldenBytes() throws {
        let previous = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Tokyo", 1); NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let root = try TestSupport.directory("r2-default-goldens")
        let goldens = [
            "false-zip": "0c6856217abd9eeb2bc666a83266a048889a5a6179952b5ebc8a837c71124abc",
            "true-zip": "7e73277c6cfde128f45ec2ceff3fd30c134c0ff5328b81836c17a696c9bf0249",
            "false-7z": "c433db55f46b5bf7f964c91352c9265ea4e5ea5efbee6c1c0a546e78f7e4f8fb",
            "true-7z": "f0e0c2e34556be8e7501589a598001112cf8a85fb10cfd2091cc087484a80193",
            "false-solid.7z": "d5bc9a5de59a0a5659cc244cbcbf1b962a8a5d66724f6ab7384c84ea93857b01",
            "true-solid.7z": "f0e0c2e34556be8e7501589a598001112cf8a85fb10cfd2091cc087484a80193",
            "false-tar.xz": "3966ddb2ab6359460b6c8f7b0015e4e9b9c65130e81dd122edb22745c578f171",
            "true-tar.xz": "892e01a558cf3bbfb29b987d0cc469748ba6709f9f98234f7adaf421ba8accf8"
        ]
        for (name, format, solid): (String, ArchiveFormat, SevenZipSolidMode) in [
            ("zip", .zip, .off), ("7z", .sevenZip, .off), ("solid.7z", .sevenZip, .on()), ("tar.xz", .tarXZ, .off)
        ] {
            for enabled in [false, true] {
                let key = "\(enabled)-\(name)"
                let url = root.appendingPathComponent(format == .tarXZ ? "golden-\(enabled).tar.xz" : key)
                let writer = try ArchiveWriter.create(url: url, format: format,
                    options: .init(sevenZipSolid: solid, useCompressionHeuristic: enabled, compressionThreads: 1))
                let items: [ExpectedEntry] = [.init(name: "page.avif", data: Data(repeating: 65, count: 1_001)),
                                              .init(name: "tail.txt", data: Data("tail".utf8))]
                for item in items { try writer.add(data: item.data, as: item.name, modificationDate: TestSupport.date) }
                try writer.finish()
                let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                TestSupport.report("R2-GOLDEN \(key) \(hash)")
                XCTAssertEqual(hash, goldens[key], key)
                try TestSupport.assertKaitoKitRoundTrip(url, expected: items)
                try TestSupport.run(ReferenceTool.sevenZip, ["t", url.path], in: root, log: key + "-7zz")
            }
        }
    }
}
