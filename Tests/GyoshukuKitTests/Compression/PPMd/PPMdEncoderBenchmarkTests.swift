// 出自: 公開ドメインの LZMA SDK 26.03 C/Ppmd7Enc.c と 7-Zip 26.03 C/Ppmd8Enc.c。
import Foundation
import XCTest
@testable import GyoshukuKit

/// 入力準備・復号は計測外。Swift は allocation / finish、7zz は起動 / file I/O を含む best-of-5。
final class PPMdEncoderBenchmarkTests: XCTestCase {
    func testSingleThreadBenchmark() throws {
        try OptInGate.flag("GYOSHUKU_PPMD_BENCHMARK")
        #if DEBUG
        XCTFail("Run PPMdEncoderBenchmarkTests with -c release")
        return
        #else
        let directory = try TestSupport.directory("ppmd-encoder-benchmark")
        let text = TestCorpus.englishLike(size: 8 << 20)
        let binary = try binaryCorpus()
        let version = try ReferenceTool.run(ReferenceTool.sevenZip, ["i"], in: directory, log: "version")
        TestSupport.report("PPMD-BENCH-TOOL\t" + (version.utf8Text.split(separator: "\n").first.map(String.init) ?? "7zz"))
        TestSupport.report("PPMD-BENCH\tcorpus\tvariant\tlevel\tencoder\tbytes\tMB/s\tseconds")
        for (name, input) in [("text", text), ("binary", binary)] {
            TestSupport.report("PPMD-BENCH-CORPUS\t\(name)\t\(input.count)")
            let plain = directory.appendingPathComponent(name + ".bin")
            try input.write(to: plain)
            for variantI in [false, true] {
                let variant = variantI ? "I" : "H", ext = variantI ? "zip" : "7z"
                for level in [1, 6, 9] {
                    let h = try PPMd7EncoderProperties.preset(level)
                    let i = try PPMd8EncoderProperties.preset(level)
                    let order = variantI ? i.order : h.order, memory = (variantI ? i.memorySize : h.memorySize) >> 20
                    let label = "\(name)-\(variant)-\(level)"
                    let memoryTag = h.memorySize.nonzeroBitCount == 1 ? String(h.memorySize.trailingZeroBitCount) : "\(memory)m"
                    var encoded = Data(), fastest = Double.infinity
                    for _ in 0..<5 {
                        let start = ProcessInfo.processInfo.systemUptime
                        encoded = variantI ? try PPMd8StreamEncoder.encode(input, properties: i)
                                           : try PPMd7StreamEncoder.encode(input, properties: h)
                        fastest = min(fastest, ProcessInfo.processInfo.systemUptime - start)
                    }
                    report(name, variant, level, "swift", encoded.count, fastest, input.count)
                    let archive = variantI ? PPMdTestArchives.zip(encoded, input: input)
                                           : PPMdTestArchives.sevenZip(encoded, input: input, properties: h)
                    try PPMdTestArchives.verify(archive, input: input, extension: ext,
                        method: variantI ? "PPMd" : "PPMD:o\(order):mem\(memoryTag)",
                        label: label, directory: directory)
                    // ZIP は a=0 で restart を指定。7zz は小さい入力で heap を縮小するため実値も記録する。
                    let method = variantI ? ["-tzip", "-mm=PPMd:o=\(order):mem=\(memory)m:a=0", "-mx=\(level)"]
                                          : ["-t7z", "-m0=PPMd:o=\(order):mem=\(memory)m"]
                    let reference = directory.appendingPathComponent(label + "-reference." + ext)
                    let arguments = ["a"] + method + ["-mmt=1", reference.path, plain.path]
                    TestSupport.report("PPMD-BENCH-PARAMETERS\t\(variant)\t\(level)\t" + arguments.joined(separator: " "))
                    var referenceFastest = Double.infinity
                    for run in 0..<5 {
                        if FileManager.default.fileExists(atPath: reference.path) { try FileManager.default.removeItem(at: reference) }
                        referenceFastest = min(referenceFastest, try timedReference(arguments, directory: directory, label: label, run: run))
                    }
                    let list = try ReferenceTool.run(ReferenceTool.sevenZip, ["l", "-slt", reference.path], in: directory, log: label + "-reference-list")
                    let prefix = "Packed Size = "
                    let sizes = list.utf8Text.split(separator: "\n").compactMap { line -> Int? in
                        line.hasPrefix(prefix) ? Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                    }
                    let referenceSize = try XCTUnwrap(sizes.last)
                    let referenceMemory: Int
                    if variantI {
                        let bytes = try Data(contentsOf: reference)
                        let nameCount = Int(bytes[26]) | Int(bytes[27]) << 8
                        let extraCount = Int(bytes[28]) | Int(bytes[29]) << 8
                        let offset = 30 + nameCount + extraCount
                        let word = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                        XCTAssertEqual(Int(word & 15) + 1, order)
                        XCTAssertEqual(word >> 12, i.restoration.rawValue)
                        referenceMemory = (Int((word >> 4) & 255) + 1) << 20
                    } else {
                        let prefix = "Method = PPMD:o\(order):mem"
                        let method = try XCTUnwrap(list.utf8Text.split(separator: "\n").last { $0.hasPrefix(prefix) })
                        let tag = method.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                        if tag.hasSuffix("m") { referenceMemory = try XCTUnwrap(Int(tag.dropLast())) << 20 }
                        else { referenceMemory = 1 << (try XCTUnwrap(Int(tag))) }
                    }
                    if level != 9 { XCTAssertEqual(referenceMemory >> 20, memory) }
                    else { XCTAssertLessThanOrEqual(referenceMemory >> 20, memory) }
                    TestSupport.report("PPMD-BENCH-ACTUAL\t\(name)\t\(variant)\t\(level)\torder=\(order)\theapMiB=\(referenceMemory >> 20)\trestoration=restart")
                    try StreamEncoderTestSupport.assertCLI(ReferenceTool.sevenZip, arguments: ["x", "-so"], url: reference,
                                                          input: input, in: directory, label: label + "-reference-extract")
                    report(name, variant, level, "7zz", referenceSize, referenceFastest, input.count)
                    TestSupport.report(String(format: "PPMD-BENCH-TARGET\t%@\t%@\t%d\tspeed/7zz=%.3f\tsize-gap=%.3f%%", name, variant, level,
                                              referenceFastest / fastest, 100 * (Double(encoded.count) / Double(referenceSize) - 1)))
                }
            }
        }
        #endif
    }

    private func report(_ name: String, _ variant: String, _ level: Int, _ encoder: String,
                        _ bytes: Int, _ seconds: Double, _ count: Int) {
        TestSupport.report(String(format: "PPMD-BENCH\t%@\t%@\t%d\t%@\t%d\t%.3f\t%.6f", name, variant, level,
                                  encoder, bytes, Double(count) / 1_000_000 / seconds, seconds))
    }

    private func timedReference(_ arguments: [String], directory: URL, label: String, run: Int) throws -> Double {
        let log = directory.appendingPathComponent("\(label)-reference-\(run).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(), completion = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: ReferenceTool.sevenZip)
        process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        process.environment = ProcessInfo.processInfo.environment.merging(ReferenceTool.englishUTF8) { $1 }
        process.terminationHandler = { _ in completion.signal() }
        let start = ProcessInfo.processInfo.systemUptime
        try process.run()
        completion.wait()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let diagnostic = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        return elapsed
    }

    private func binaryCorpus() throws -> Data {
        let paths = ["/usr/lib/dyld", "/usr/bin/swift", "/bin/bash"]
        for path in paths where FileManager.default.isReadableFile(atPath: path) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let magic = Array(bytes.prefix(4))
            guard magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE]
                    || magic == [0xFE, 0xED, 0xFA, 0xCF] else { continue }
            let result = Data(bytes.prefix(16 << 20))
            TestSupport.report("PPMD-BENCH-SOURCE\t\(path)\t\(result.count)")
            return result
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
