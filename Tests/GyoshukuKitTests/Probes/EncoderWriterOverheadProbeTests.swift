import Foundation
import XCTest
@testable import GyoshukuKit

/// writer 内に計測 hook を追加せず、同じ入力の Copy 経路で I/O・filter・暗号化の費用を測る。
/// 圧縮後の byte 数とは異なるので、encoder の差引き時間は近似として扱う。
final class EncoderWriterOverheadProbeTests: XCTestCase {
    func testCopyControlsOnOriginalWriterCorpora() throws {
        try OptInGate.flag("GYOSHUKU_ENCODER_TIMING")
        let root = try TestSupport.directory("encoder-writer-overhead")
        let text = EncoderTestCorpus.sourceTwentyMiB
        for format in [ArchiveFormat.zip, .sevenZip] {
            let items = [ExpectedEntry(name: "large.txt", data: text)]
                + (format == .sevenZip ? [.init(name: "tail", data: Data([3, 4, 5]))] : [])
            let options = WriterOptions(compressionMethod: .stored, sevenZipMethod: .copy,
                sevenZipSolid: .on(), useCompressionHeuristic: false, compressionThreads: 1)
            try copyControl(root, label: "\(format)-20m", format: format, options: options, items: items)
        }
        for (filter, label, arm64) in [(SevenZipFilterMode.none, "none", false),
            (.bcjX86, "bcj", false), (.arm64, "arm64", true), (.delta(distance: 4), "delta", false)] {
            let items: [ExpectedEntry] = [.init(name: "one", data: SevenZipSolidFilterSupport.macho(arm64: arm64)),
                .init(name: "empty"), .init(name: "two", data: SevenZipSolidFilterSupport.macho(arm64: arm64, size: 262_149))]
            for solid in [false, true] {
                for encrypted in [false, true] {
                    let options = WriterOptions(sevenZipMethod: .copy, sevenZipSolid: solid ? .on() : .off,
                        sevenZipFilter: filter, password: encrypted ? "secret" : nil,
                        encryptsSevenZipHeaders: encrypted, compressionThreads: 4)
                    try copyControl(root, label: "filter-\(label)-\(solid)-\(encrypted)", format: .sevenZip,
                        options: options, items: items)
                }
            }
        }
        try copyControl(root, label: "tar-128m", format: .tar, options: .init(),
            items: [.init(name: "large", data: Data(repeating: 0x5A, count: 128 << 20))])
        // APFS clone ではなく、実際に read / write する単独 stream の I/O 対照。
        for (name, input) in [("text-1m", EncoderTestCorpus.sourceMiB), ("random-9m", EncoderTestCorpus.randomNineMiB)] {
            let source = root.appendingPathComponent(name + ".raw"), output = root.appendingPathComponent(name + ".copy")
            try input.write(to: source)
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let reader = try FileHandle(forReadingFrom: source), writer = try FileHandle(forWritingTo: output)
            let start = EncoderTestTiming.start()
            while let bytes = try reader.read(upToCount: IOChunk.size), !bytes.isEmpty { try writer.write(contentsOf: bytes) }
            try reader.close(); try writer.close()
            EncoderTestTiming.end("test.file-copy.\(name)", start, input: input.count, output: input.count)
            XCTAssertEqual(try Data(contentsOf: output), input)
        }
    }

    private func copyControl(_ root: URL, label: String, format: ArchiveFormat,
                             options: WriterOptions, items: [ExpectedEntry]) throws {
        let work = try TestSupport.work(in: root), url = work.appendingPathComponent("archive." + format.testFileExtension)
        let start = EncoderTestTiming.start()
        try PPMdWriterTestSupport.write(url, format: format, options: options, items: items)
        EncoderTestTiming.end("test.copy-control.\(label)", start, input: items.reduce(0) { $0 + $1.data.count },
            output: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try TestSupport.assertKaitoKitRoundTrip(url, expected: items, password: options.password)
    }
}
