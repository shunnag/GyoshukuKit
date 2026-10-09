import Foundation
import XCTest
@testable import GyoshukuKit

/// 外部scratch corpusを使う比率計測。通常試験では走らせない。
final class SpeedPriorityRatioProbeTests: XCTestCase {
    private static let configurations: [(String, SingleStreamFormat?, ArchiveFormat?, WriterOptions)] = [
        ("xz-apple", .xz, nil, .init()), ("xz-6", .xz, nil, .init(lzmaLevel: 6)),
        ("lzip-6", .lzip, nil, .init(lzmaLevel: 6)),
        ("zip-zstd-3", nil, .zip, .init(compressionMethod: .zstd)),
        ("7z-solid-apple", nil, .sevenZip, .init(sevenZipSolid: .on())),
        ("7z-solid-6", nil, .sevenZip, .init(sevenZipSolid: .on(), lzmaLevel: 6))
    ]

    func testRatioAndSpeedOutputSizes() throws {
        let corpus = try OptInGate.path("GYOSHUKU_SPEED_RATIO_CORPUS")
        let directory = try TestSupport.directory("speed-priority-ratio")
        var rows: [[String: Any]] = []
        for name in ["hdr32.txt", "bin32", "mixed32.bin"] {
            let source = corpus.appendingPathComponent(name)
            let input = try Data(contentsOf: source)
            for (label, stream, archive, base) in Self.configurations {
                var sizes: [Int] = []
                for speed in [false, true] {
                    var options = base
                    options.prefersSpeed = speed; options.compressionThreads = 4; options.useCompressionHeuristic = false
                    let url = directory.appendingPathComponent("\(name)-\(label)-\(speed)")
                    if let stream { try SingleStreamCompressor.compress(file: source, to: url, format: stream, options: options) }
                    else {
                        let writer = try ArchiveWriter.create(url: url, format: archive!, options: options)
                        if archive == .sevenZip {
                            // solid上限が実際に複数folderを作るよう、同じ32 MiBを四つのmemberにする。
                            for offset in stride(from: 0, to: input.count, by: 8 << 20) {
                                try writer.add(data: input.subdata(in: offset..<min(input.count, offset + (8 << 20))),
                                    as: "part-\(offset)", modificationDate: TestSupport.date)
                            }
                        } else { try writer.add(data: input, as: "input", modificationDate: TestSupport.date) }
                        try writer.finish()
                    }
                    sizes.append(try Data(contentsOf: url).count)
                }
                let change = Double(sizes[1] - sizes[0]) * 100 / Double(sizes[0])
                let row: [String: Any] = ["corpus": name, "format": label, "ratio_bytes": sizes[0], "speed_bytes": sizes[1], "change_percent": change]
                rows.append(row)
                TestSupport.report("SPEED_RATIO corpus=\(name) format=\(label) ratio=\(sizes[0]) speed=\(sizes[1]) change=\(String(format: "%.2f", change))%")
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("sizes.json"))
        try verify(corpus: corpus, directory: directory)
    }

    // 既に採取した大きいprobe出力を再圧縮せず検査する。
    func testSavedProbeRoundTrips() throws {
        try OptInGate.flag("GYOSHUKU_SPEED_RATIO_VERIFY")
        let corpus = try OptInGate.path("GYOSHUKU_SPEED_RATIO_CORPUS")
        try verify(corpus: corpus, directory: TestPaths.verification.appendingPathComponent("speed-priority-ratio"))
    }

    private func verify(corpus: URL, directory: URL) throws {
        for name in ["hdr32.txt", "bin32", "mixed32.bin"] {
            let input = try Data(contentsOf: corpus.appendingPathComponent(name))
            for (label, stream, archive, _) in Self.configurations {
                for speed in [false, true] {
                    let url = directory.appendingPathComponent("\(name)-\(label)-\(speed)")
                    if let stream {
                        try StreamEncoderTestSupport.assertKaito(url, equals: input)
                        try ReferenceTool.run(stream == .xz ? ReferenceTool.xz : ReferenceTool.lzip, ["-t", url.path],
                            in: directory, log: url.lastPathComponent + "-test")
                    } else {
                        let expected: [ExpectedEntry]
                        if archive == .sevenZip {
                            expected = stride(from: 0, to: input.count, by: 8 << 20).map { offset in
                                .init(name: "part-\(offset)", data: input.subdata(in: offset..<min(input.count, offset + (8 << 20))))
                            }
                        } else { expected = [.init(name: "input", data: input)] }
                        try TestSupport.assertKaitoKitRoundTrip(url, expected: expected)
                        try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path], in: directory, log: url.lastPathComponent + "-test")
                        if archive == .zip {
                            let zip = ZipBytes(data: try Data(contentsOf: url))
                            let start = 30 + Int(zip.u16(26)) + Int(zip.u16(28))
                            let payload = directory.appendingPathComponent(url.lastPathComponent + ".zst")
                            try zip.data.subdata(in: start..<(start + Int(zip.u32(18)))).write(to: payload)
                            try ReferenceTool.run(ReferenceTool.zstd, ["-t", payload.path], in: directory, log: payload.lastPathComponent + "-test")
                        }
                    }
                }
            }
        }
    }
}
