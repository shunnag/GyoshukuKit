import Foundation
import GyoshukuKit
private import Darwin

private let usage = """
Usage: gyoshuku-bench <zip|tar|tgz|tbz|txz|7z|lha> <output> <source>... [--level N] [--threads N]
  --level N    deflateLevel, 0...9 (ZIP / tar.gz; default 6)
  --threads N  compressionThreads, 1...64 (default: library auto selection)
  --           Treat remaining arguments as source paths
Output must be a new file. Directories are added recursively under their basename.
"""

private struct ArgumentError: Error, CustomStringConvertible {
    let description: String
}

private func benchmark(_ arguments: [String]) throws {
    guard arguments.count >= 3 else { throw ArgumentError(description: usage) }
    let format: ArchiveFormat
    switch arguments[0] {
    case "zip": format = .zip
    case "tar": format = .tar
    case "tgz": format = .tarGzip
    case "tbz": format = .tarBzip2
    case "txz": format = .tarXZ
    case "7z": format = .sevenZip
    case "lha": format = .lha
    default: throw ArgumentError(description: "Unknown format: \(arguments[0])\n\(usage)")
    }

    let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    var options = WriterOptions()
    var sources: [URL] = []
    var index = 2
    var parseOptions = true
    while index < arguments.count {
        let argument = arguments[index]
        if parseOptions && argument == "--" {
            parseOptions = false
        } else if parseOptions && (argument == "--level" || argument == "--threads") {
            let range = argument == "--level" ? 0...9 : 1...64
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]), range.contains(value) else {
                throw ArgumentError(description: "\(argument) requires an integer in \(range).")
            }
            if argument == "--level" { options.deflateLevel = value }
            else { options.compressionThreads = value }
            index += 1
        } else if parseOptions && argument.hasPrefix("-") {
            throw ArgumentError(description: "Unknown option: \(argument). Use -- before a source starting with '-'.")
        } else {
            sources.append(URL(fileURLWithPath: argument).standardizedFileURL)
        }
        index += 1
    }
    guard !sources.isEmpty else { throw ArgumentError(description: "At least one source is required.\n\(usage)") }

    let resolvedOutput = output.resolvingSymlinksInPath().path
    for source in sources {
        let sourcePath = source.resolvingSymlinksInPath().path
        guard resolvedOutput != sourcePath,
              !resolvedOutput.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/") else {
            throw ArgumentError(description: "Output must be outside the sources: \(source.path)")
        }
    }

    let threads: Int
    switch format {
    case .tar: threads = 1
    default:
        // 報告値だけ WriterOptions.resolvedCompressionThreads と揃え、nil はそのまま渡す。
        threads = options.compressionThreads ?? max(1, min(
            ProcessInfo.processInfo.activeProcessorCount, 8,
            Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
        ))
    }

    let clock = ContinuousClock()
    let start = clock.now
    let writer = try ArchiveWriter.create(url: output, format: format, options: options)
    for source in sources {
        try writer.add(contentsOf: source, as: source.lastPathComponent)
    }
    try writer.finish()
    let elapsed = start.duration(to: clock.now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    guard let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw ArgumentError(description: "Cannot read output size: \(output.path)")
    }
    let duration = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    print("\(arguments[0]) elapsed_s=\(duration) output_bytes=\(bytes) threads=\(threads)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
} else {
    do {
        try benchmark(arguments)
    } catch {
        FileHandle.standardError.write(Data("gyoshuku-bench: \(error)\n".utf8))
        exit(1)
    }
}
