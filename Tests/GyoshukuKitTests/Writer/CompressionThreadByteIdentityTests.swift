import Foundation
import XCTest
@testable import GyoshukuKit

final class CompressionThreadByteIdentityTests: XCTestCase {
    func testRepresentativeArchivesAtOneEightThirtySixAndSixtyFourThreads() throws {
        let root = try TestSupport.directory("topology-byte-identity")
        var configurations: [(ArchiveFormat, WriterOptions)] =
            [CompressionMethod.deflate, .bzip2, .lzma, .zstd, .ppmd].map {
                (.zip, WriterOptions(compressionMethod: $0, useCompressionHeuristic: false))
            }
        configurations += [(.tarXZ, .init()), (.tarXZ, .init(lzmaLevel: 0)), (.tarBzip2, .init(bzip2Level: 1)), (.tarZstd, .init())]
        for method: SevenZipCompressionMethod in [.lzma2, .lzma] {
            for solid: SevenZipSolidMode in [.off, .on(blockSize: 48 << 10)] {
                configurations.append((.sevenZip, .init(sevenZipMethod: method, sevenZipSolid: solid, lzmaLevel: 0)))
            }
        }
        configurations.append((.sevenZip, .init()))
        configurations.append((.sevenZip, .init(sevenZipSolid: .on(blockSize: 48 << 10))))
        configurations.append((.lha, .init(lhaMethod: .lh7)))
        let payload = Data(String(repeating: "topology independent compression 日本語\n", count: 600).utf8)
        for (index, configuration) in configurations.enumerated() {
            let (format, baseOptions) = configuration
            var baseline: Data?
            for threads in [1, 8, 36, 64] {
                var options = baseOptions
                options.compressionThreads = threads
                let url = root.appendingPathComponent("\(index)-\(threads)")
                let writer = try ArchiveWriter.create(url: url, format: format, options: options)
                for item in 0..<4 {
                    try writer.add(data: payload, as: "file-\(item)", modificationDate: TestSupport.date)
                }
                try writer.add(data: Data(), as: "empty", modificationDate: TestSupport.date)
                try writer.addDirectory("directory", modificationDate: TestSupport.date, ownerIDs: nil)
                try writer.finish()
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "configuration=\(index), threads=\(threads)") }
                else { baseline = bytes }
            }
        }
    }

    func testBzip2ArchivesKeepIdentityAcrossTheRealForcedCut() throws {
        let root = try TestSupport.directory("topology-bzip2-forced-cut-identity")
        // RLEで一blockがcapを超える入力。公開経路の8 MiB切断と既知サイズの逐次分岐も検査する。
        let payload = Data(repeating: 65, count: ParallelBzip2StreamEncoder.inputCap + 4096)
        for format: ArchiveFormat in [.zip, .sevenZip] {
            var baseline: Data?
            for threads in [1, 2, 7, 12, 36, 64] {
                let options = WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .bzip2,
                    useCompressionHeuristic: false, compressionThreads: threads)
                let url = root.appendingPathComponent("\(format)-\(threads)")
                let writer = try ArchiveWriter.create(url: url, format: format, options: options)
                try writer.add(data: payload, as: "long-run", modificationDate: TestSupport.date)
                try writer.add(data: Data([66]), as: "last", modificationDate: TestSupport.date)
                try writer.finish()
                let bytes = try Data(contentsOf: url)
                if let baseline { XCTAssertEqual(bytes, baseline, "\(format), threads=\(threads)") }
                else { baseline = bytes }
            }
        }
    }
}
