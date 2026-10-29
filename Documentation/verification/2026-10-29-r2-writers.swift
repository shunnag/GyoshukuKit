// Public-API release probe. See the matching .md for build and invocation.
import Foundation
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let name = args[2], mode = args[3], threads = Int(args[4])!
let output = root.deletingLastPathComponent().appendingPathComponent(name == "tar.xz" ? "probe.tar.xz" : "probe.archive")
let fm = FileManager.default
let files = (fm.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL])
    .sorted { $0.path < $1.path }
let regular = try files.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
func relative(_ file: URL) -> String { String(file.path.dropFirst(root.path.count + 1)) }
for file in files + [root] {
    var times = [timeval(tv_sec: 1_700_000_000, tv_usec: 0), timeval(tv_sec: 1_700_000_000, tv_usec: 0)]
    guard file.withUnsafeFileSystemRepresentation({ utimes($0, &times) }) == 0 else { fatalError("utimes") }
}
try? fm.removeItem(at: output)
defer { try? fm.removeItem(at: output) }
var options = WriterOptions(compressionThreads: threads, powerPolicy: .alwaysUseAllCores)
if ProcessInfo.processInfo.environment["R2_HEURISTIC"] == "0" { options.useCompressionHeuristic = false }
let format: GyoshukuKit.ArchiveFormat
switch name {
case "zip": format = .zip
case "zip-stored": format = .zip; options.compressionMethod = .stored
case "7z": format = .sevenZip
case "7z-copy": format = .sevenZip; options.sevenZipMethod = .copy
case "7z-solid": format = .sevenZip; options.sevenZipSolid = .on()
case "tar.xz": format = .tarXZ
case "tar": format = .tar
case "lha": format = .lha; options.lhaMethod = .stored
default: fatalError(name)
}
var before = rusage(), after = rusage()
getrusage(RUSAGE_SELF, &before)
let start = DispatchTime.now().uptimeNanoseconds
try autoreleasepool {
    let writer = try ArchiveWriter.create(url: output, format: format, options: options)
    if mode == "batch" {
        try writer.add(regular.map { .init(path: "tree/" + relative($0), source: .contents(of: $0)) }, events: nil)
    } else { try writer.add(contentsOf: root, as: "tree") }
    try writer.finish()
}
let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
getrusage(RUSAGE_SELF, &after)
func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
let bytes = try Data(contentsOf: output, options: .mappedIfSafe)
let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
// Verification is outside the timed region, for every measured archive.
let reader = try ArchiveReader.open(url: output)
var count = 0
for entry in reader.entries where entry.kind == .file {
    let file = root.appendingPathComponent(String(entry.name.dropFirst(5)))
    let expected = try Data(contentsOf: file)
    guard try reader.read(entry) == expected else { fatalError("KaitoKit: \(entry.name)") }
    count += 1
}
guard count == regular.count else { fatalError("entry count") }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
process.arguments = ["t", output.path]
let log = output.deletingLastPathComponent().appendingPathComponent("7zz.log")
fm.createFile(atPath: log.path, contents: nil)
let handle = try FileHandle(forWritingTo: log)
process.standardOutput = handle; process.standardError = handle
try process.run(); process.waitUntilExit(); try handle.close()
let text = try String(contentsOf: log, encoding: .utf8)
guard process.terminationStatus == 0, text.contains("Everything is Ok"),
      !text.lowercased().contains("headers error") else { fatalError("7zz: \(text)") }
let row: [String: Any] = ["case": name, "mode": mode, "threads": threads, "wall_s": wall,
    "cpu_s": cpu, "bytes": bytes.count, "sha256": hash, "files": count, "kaito": "pass", "7zz_t": 0]
print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
