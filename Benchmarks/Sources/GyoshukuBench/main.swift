import Foundation
import GyoshukuKit
private import Darwin

private let usage = """
Usage: gyoshuku-bench <zip|tar|tgz|tbz|txz|7z|lha> <output> <source>... [--level N] [--threads N] [--progress] [--mode recursive|items|batch]
  --level N    deflateLevel, 0...9 (ZIP / tar.gz; default 6)
  --threads N  compressionThreads, \(WriterOptions.compressionThreadsRange) (default: library auto selection)
  --progress   Observe add and finishAdditions byte progress
  --mode MODE  recursive (default), sorted preorder items, or batch; enumeration is timed
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
    var reportsProgress = false
    var mode = "recursive"
    while index < arguments.count {
        let argument = arguments[index]
        if parseOptions && argument == "--" {
            parseOptions = false
        } else if parseOptions && argument == "--progress" {
            reportsProgress = true
        } else if parseOptions && argument == "--mode" {
            guard index + 1 < arguments.count, ["recursive", "items", "batch"].contains(arguments[index + 1]) else {
                throw ArgumentError(description: "--mode requires recursive, items or batch.")
            }
            index += 1
            mode = arguments[index]
        } else if parseOptions && (argument == "--level" || argument == "--threads") {
            let range = argument == "--level" ? 0...9 : WriterOptions.compressionThreadsRange
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
        // library の公開 API で開始直前の自動要求値を表示する。
        threads = options.compressionThreads ?? WriterOptions.automaticCompressionThreads(powerPolicy: options.powerPolicy)
    }

    let clock = ContinuousClock()
    let start = clock.now
    let writer = try ArchiveWriter.create(url: output, format: format, options: options)
    func add(_ source: URL, as path: String) throws {
        if reportsProgress { try writer.add(contentsOf: source, as: path, progress: { _ in }) }
        else { try writer.add(contentsOf: source, as: path) }
    }
    if mode != "recursive" {
        var items: [(url: URL, path: String, directory: Bool)] = []
        func walk(_ url: URL, path: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "lstat", code: errno) }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            items.append((url, path, directory))
            if directory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .map { (url: $0, name: $0.lastPathComponent) }.sorted { $0.name < $1.name }
                for child in children { try walk(child.url, path: path + "/" + child.name) }
            }
        }
        for source in sources { try walk(source, path: source.lastPathComponent) }
        if mode == "batch" {
            let additions = items.map { ArchiveAddition(path: $0.path,
                source: $0.directory ? .directory(modificationDate: nil) : .contents(of: $0.url)) }
            try writer.add(additions, events: reportsProgress ? { _ in } : nil)
        } else {
            for item in items {
                if item.directory { try writer.addDirectory(item.path) }
                else { try add(item.url, as: item.path) }
            }
        }
    } else {
        for source in sources { try add(source, as: source.lastPathComponent) }
    }
    if reportsProgress { try writer.finishAdditions(progress: { _ in }) }
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
