import Foundation
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit

/// 同じ入力・固定時刻で writer の wall / process CPU を測る。通常試験では実行しない。
func benchmark() throws {
    let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1])
        let destination = URL(fileURLWithPath: arguments[2])
        let cases = [arguments[3]]
        let threads = Int(arguments[4])!
        let label = arguments[5]
        let workload = arguments[6]
        let mode = arguments.count > 7 ? arguments[7] : "item"
        let prefersSpeed = ProcessInfo.processInfo.environment["GYOSHUKU_BENCH_PREFERS_SPEED"] == "1"
        guard mode == "item" || mode == "batch" else { throw WriterError.invalidOption(mode) }
        let members = workload == "corpus" ? "mixed" : workload
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(members), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let inputs = workload == "tree" ? (FileManager.default.enumerator(at: root.appendingPathComponent(members), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?.allObjects as? [URL] ?? []) : files
        let inputBytes = try inputs.reduce(0) { total, file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return total + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
        }
        for name in cases {
            var options = WriterOptions(useCompressionHeuristic: false, compressionThreads: threads)
            options.prefersSpeed = prefersSpeed
            if workload == "zipcrypto" { options.password = "benchmark-secret"; options.zipEncryption = .zipCrypto }
            // 生の LZMA1 は既定6、LZMA2/XZ は凍結された Apple nil-level 経路。
            let output = root.appendingPathComponent("result-\(label).archive")
            try? FileManager.default.removeItem(at: output)
            // 列挙とresourceValuesの後、計時直前にUT atime/mtimeを固定する。
            for file in inputs + [root.appendingPathComponent(members)] {
                var stamps = [timeval(tv_sec: 1_700_000_000, tv_usec: 0), timeval(tv_sec: 1_700_000_000, tv_usec: 0)]
                guard file.withUnsafeFileSystemRepresentation({ utimes($0, &stamps) }) == 0 else {
                    throw WriterError.io(operation: "utimes", code: errno)
                }
            }
            var before = rusage(), after = rusage()
            getrusage(RUSAGE_SELF, &before)
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
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
                    let format: GyoshukuKit.ArchiveFormat
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
                        if parts.contains("solid") { options.sevenZipSolid = workload == "single" ? .on() : .on(blockSize: 16 << 20, filesPerBlock: nil) }
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
                    if mode == "batch" {
                        try writer.add(files.map { ArchiveAddition(path: $0.lastPathComponent, source: .contents(of: $0)) }, events: nil)
                    } else {
                        for file in files { try writer.add(contentsOf: file, as: file.lastPathComponent) }
                    }
                    try writer.finish()
                }
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            getrusage(RUSAGE_SELF, &after)
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
            let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var row: [String: Any] = ["label": label, "path": name, "threads": threads, "wall_s": wall,
                                      "cpu_s": cpu, "output_bytes": data.count, "sha256": hash,
                                      "input_bytes": inputBytes,
                                      "workload": workload, "load": load, "level": workload == "single" ? "defaults; solid=default" : "defaults; solid=16MiB; filter=delta4"]
            if workload == "zipcrypto" {
                // headerは乱数なので、計時外に復号した全本文のdigestを照合する。
                let reader = try ArchiveReader.open(url: output, options: ReaderOptions(password: options.password))
                var content = SHA256()
                for entry in reader.entries {
                    content.update(data: Data(entry.name.utf8))
                    content.update(data: Data([0]))
                    content.update(data: try reader.read(entry))
                }
                row["content_sha256"] = content.finalize().map { String(format: "%02x", $0) }.joined()
            }
            if mode == "batch" { row["mode"] = mode }
            if prefersSpeed { row["prefers_speed"] = true }
            var json = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            json.append(10)
            if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd(); try handle.write(contentsOf: json); try handle.close()
            print("MULTICORE \(String(decoding: json, as: UTF8.self))")
            try FileManager.default.removeItem(at: output)
        }
}
try benchmark()
