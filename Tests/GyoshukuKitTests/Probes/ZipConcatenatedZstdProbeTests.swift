import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

/// ZIP 93 の frame 連結を二つの独立 decoder で確認する。writer の出力方式は変更しない。
final class ZipConcatenatedZstdProbeTests: XCTestCase {
    func testLargeMemberFrameResetSize() throws {
        try OptInGate.flag("GYOSHUKU_MULTICORE_BENCHMARK")
        let corpus = try OptInGate.path("GYOSHUKU_MULTICORE_CORPUS")
        let input = try Data(contentsOf: corpus.appendingPathComponent("mixed/z-large.dat"))
        let options = WriterOptions(compressionMethod: .zstd, compressionThreads: 1)
        let configuration = try ZstdWriterConfiguration(options: options)
        var serial = Data(), offset = 0
        _ = try ZipEntryCompressor(options: options).compress(name: "large", size: UInt64(input.count), method: .zstd,
            read: { count in
                let end = min(input.count, offset + count)
                defer { offset = end }
                return input.subdata(in: offset..<end)
            }, emit: { serial.append($0) })
        var frames = Data()
        for start in stride(from: 0, to: input.count, by: configuration.chunkSize) {
            frames.append(try ZstdFrameEncoder.encode(input.subdata(in: start..<min(input.count, start + configuration.chunkSize)),
                                                       level: options.zstdLevel))
        }
        let directory = try TestSupport.directory("multicore-zstd-large-frame-reset")
        let url = directory.appendingPathComponent("concatenated.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = ZipWriter(output: try FileHandle(forWritingTo: url), url: url, options: options,
                               deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
        let entry = try writer.makeEntry(name: "large", mode: 0o100644, size: UInt64(input.count),
                                         date: TestSupport.date, atime: nil, owners: nil)
        try writer.emitComplete(entry, data: frames, crc: updateCRC(0, input))
        try writer.finish(existingCount: 0, comment: Data(), progress: nil, copyCentral: { _ in })
        let oracle = try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path], in: directory, log: "7zz-t")
        let reader = try ArchiveReader.open(url: url)
        let decoded = try reader.read(XCTUnwrap(reader.entries.first))
        XCTAssertTrue(decoded == input, "concatenated ZIP frames must restore the large member")
        let source = corpus.deletingLastPathComponent().appendingPathComponent("results.jsonl")
        let samples = try String(contentsOf: source, encoding: .utf8).split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let baseline = try XCTUnwrap(samples.first { $0["path"] as? String == "zip-zstd" && $0["label"] as? String == "base" }?["output_bytes"] as? Int)
        let candidate = baseline - serial.count + frames.count
        let row: [String: Any] = ["level": options.zstdLevel, "input_bytes": input.count,
                                  "chunk_bytes": configuration.chunkSize, "single_frame_bytes": serial.count,
                                  "concatenated_frame_bytes": frames.count, "baseline_zip_bytes": baseline,
                                  "candidate_zip_bytes": candidate, "zip_size_change_percent": Double(candidate - baseline) * 100 / Double(baseline),
                                  "7zz_status": oracle.status, "kaito_accepts": decoded == input]
        var json = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        json.append(10)
        try json.write(to: corpus.deletingLastPathComponent().appendingPathComponent("zstd-frame-ratio.jsonl"))
        print("ZIP_ZSTD_FRAME_RATIO \(String(decoding: json, as: UTF8.self))")
    }

    func testIndependentReaders() throws {
        try OptInGate.flag("GYOSHUKU_MULTICORE_BENCHMARK")
        let directory = try TestSupport.directory("multicore-zstd-concatenation")
        let url = directory.appendingPathComponent("concatenated.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let options = WriterOptions(compressionMethod: .zstd, compressionThreads: 1)
        let writer = ZipWriter(output: try FileHandle(forWritingTo: url), url: url, options: options,
                               deflateBlockSize: DeflateBlock.size, deflateEncoder: DeflateBlock.encode, salt: { Data(count: 16) })
        let first = Data(repeating: 65, count: 131_071), second = Data(repeating: 66, count: 131_073)
        let input = first + second
        let compressed = try ZstdFrameEncoder.encode(first) + ZstdFrameEncoder.encode(second)
        let entry = try writer.makeEntry(name: "two-frames", mode: 0o100644, size: UInt64(input.count),
                                         date: TestSupport.date, atime: nil, owners: nil)
        try writer.emitComplete(entry, data: compressed, crc: updateCRC(0, input))
        try writer.finish(existingCount: 0, comment: Data(), progress: nil, copyCentral: { _ in })
        let oracle = try ReferenceTool.run(ReferenceTool.sevenZip, ["t", url.path], in: directory,
                                           log: "7zz-t", expect: .unchecked)
        var kaitoAccepts = false
        var diagnostic = ""
        do {
            let reader = try ArchiveReader.open(url: url)
            kaitoAccepts = try reader.read(XCTUnwrap(reader.entries.first)) == input
        } catch { diagnostic = String(describing: error) }
        print("ZIP_ZSTD_CONCAT 7zz_status=\(oracle.status) kaito_accepts=\(kaitoAccepts) diagnostic=\(diagnostic)")
        // 受理・拒否のどちらも調査結果。採用は両 reader の受理と byte / size の契約を満たす場合だけ。
    }
}
