import Foundation
import CryptoKit
import XCTest
import Darwin
@testable import GyoshukuKit

/// 同じ入力・固定時刻で writer の wall / process CPU を測る。通常試験では実行しない。
final class MulticoreBenchmarkTests: XCTestCase {
    func testWriterMatrix() throws {
        try OptInGate.flag("GYOSHUKU_MULTICORE_BENCHMARK")
        let root = try OptInGate.path("GYOSHUKU_MULTICORE_CORPUS")
        let destination = try OptInGate.path("GYOSHUKU_MULTICORE_RESULTS")
        let cases = (OptInGate.value("GYOSHUKU_MULTICORE_CASES") ?? "zip-bzip2").split(separator: ",").map(String.init)
        let threads = OptInGate.integer("GYOSHUKU_MULTICORE_THREADS", default: 12)
        let label = OptInGate.value("GYOSHUKU_MULTICORE_LABEL") ?? "new"
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("mixed"), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for name in cases {
            var options = WriterOptions(useCompressionHeuristic: false, compressionThreads: threads)
            // 生の LZMA1 は既定6、LZMA2/XZ は凍結された Apple nil-level 経路。
            let output = root.appendingPathComponent("result-\(label).archive")
            try? FileManager.default.removeItem(at: output)
            var before = rusage(), after = rusage()
            getrusage(RUSAGE_SELF, &before)
            let start = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                if name.hasPrefix("stream-") {
                    let format: SingleStreamFormat = switch String(name.dropFirst(7)) {
                    case "gz": .gzip
                    case "bz2": .bzip2
                    case "xz": .xz
                    case "zst": .zstd
                    case "lz": .lzip
                    case "lzma": .lzma
                    case "lz4": .lz4
                    case "br": .brotli
                    case "Z": .compress
                    default: throw WriterError.invalidOption(name)
                    }
                    try SingleStreamCompressor.compress(file: root.appendingPathComponent("mixed.bin"), to: output, format: format, options: options)
                } else {
                    let format: ArchiveFormat
                    if name.hasPrefix("zip-") {
                        format = .zip
                        options.compressionMethod = switch String(name.dropFirst(4)) {
                        case "stored": .stored
                        case "deflate": .deflate
                        case "bzip2": .bzip2
                        case "lzma": .lzma
                        case "xz": .xz
                        case "zstd": .zstd
                        case "ppmd": .ppmd
                        default: throw WriterError.invalidOption(name)
                        }
                    } else if name.hasPrefix("7z-") {
                        format = .sevenZip
                        let parts = name.split(separator: "-")
                        options.sevenZipMethod = switch parts[1] {
                        case "lzma2": .lzma2
                        case "lzma": .lzma
                        case "deflate": .deflate
                        case "bzip2": .bzip2
                        case "ppmd": .ppmd
                        case "copy": .copy
                        default: throw WriterError.invalidOption(name)
                        }
                        if parts.contains("solid") { options.sevenZipSolid = .on(blockSize: 16 << 20, filesPerBlock: nil) }
                        if parts.contains("filter") { options.sevenZipFilter = .delta(distance: 4) }
                    } else if name.hasPrefix("lha-") {
                        format = .lha
                        options.lhaMethod = switch String(name.dropFirst(4)) {
                        case "lh5": .lh5
                        case "lh6": .lh6
                        case "lh7": .lh7
                        default: throw WriterError.invalidOption(name)
                        }
                    } else {
                        format = switch name {
                        case "tar": .tar
                        case "tar.gz": .tarGzip
                        case "tar.bz2": .tarBzip2
                        case "tar.xz": .tarXZ
                        case "tar.zst": .tarZstd
                        case "tar.lz": .tarLzip
                        case "tar.lzma": .tarLZMA
                        case "tar.lz4": .tarLZ4
                        case "tar.br": .tarBrotli
                        case "tar.Z": .tarCompress
                        default: throw WriterError.invalidOption(name)
                        }
                    }
                    let writer = try ArchiveWriter.create(url: output, format: format, options: options)
                    for file in files { try writer.add(contentsOf: file, as: file.lastPathComponent) }
                    try writer.finish()
                }
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            getrusage(RUSAGE_SELF, &after)
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
            let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let row: [String: Any] = ["label": label, "path": name, "threads": threads, "wall_s": wall,
                                      "cpu_s": cpu, "output_bytes": data.count, "sha256": hash,
                                      "input_bytes": 256 << 20, "level": "defaults; solid=16MiB; filter=delta4"]
            var json = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            json.append(10)
            if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd(); try handle.write(contentsOf: json); try handle.close()
            print("MULTICORE \(String(decoding: json, as: UTF8.self))")
            try FileManager.default.removeItem(at: output)
        }
    }
}
