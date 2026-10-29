import Foundation
import CryptoKit
import XCTest
@testable import GyoshukuKit

final class ZipAESWritingBenchmarkTests: XCTestCase {
    func testSmallEntriesAndLargeStoredEntry() throws {
        try OptInGate.flag("GYOSHUKU_ZIP_AES_BENCHMARK")
        let label = ProcessInfo.processInfo.environment["GYOSHUKU_ZIP_AES_BENCHMARK_RUN"] ?? "run"
        let root = try TestSupport.directory("zip-aes-writing-" + label)
        let source = root.appendingPathComponent("source.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512 << 20)
        try handle.close()
        try AdditionProgressTestSupport.timestamp(source)
        defer { try? FileManager.default.removeItem(at: source) }
        let small = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 * 17) })
        for workload in ["small-deflate", "small-stored", "stored-512MiB"] {
            for sample in 0..<3 {
                try AdditionProgressTestSupport.timestamp(source)
                let url = root.appendingPathComponent("\(workload)-\(sample).zip")
                let options = WriterOptions(compressionMethod: workload == "small-deflate" ? .deflate : .stored,
                    useCompressionHeuristic: false, password: EncryptionTestSupport.password, compressionThreads: 12)
                let start = DispatchTime.now().uptimeNanoseconds
                let writer = try ArchiveWriter.create(url: url, format: .zip, options: options,
                    zipSalt: { Data(repeating: 0x39, count: 16) }, lzmaChunkSize: nil)
                if workload == "stored-512MiB" {
                    try writer.add(contentsOf: source, as: "large.bin", ownerIDs: nil)
                } else {
                    for index in 0..<2_000 {
                        try writer.add(data: small, as: "file-\(index)", modificationDate: TestSupport.date)
                    }
                }
                try writer.finish()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                let input = try FileHandle(forReadingFrom: url)
                var hash = SHA256()
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                try input.close()
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                TestSupport.report("ZIP_AES_WRITING\t\(label)\t\(workload)\t\(sample)\t\(elapsed)\t\(digest)")
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
