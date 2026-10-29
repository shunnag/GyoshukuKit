import Foundation
import XCTest
@testable import GyoshukuKit

final class TarWriterBufferTests: XCTestCase {
    func testBatchFlushesAtCallbacksAndReturnWithIdenticalBytes() throws {
        let root = try TestSupport.directory("r2-tar-buffer")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try BatchAdditionTestSupport.small(root, count: 8, size: 65_537)
        var baseline: Data?
        for mode in 0..<3 {
            let output = root.appendingPathComponent("\(mode).tar")
            let writer = try ArchiveWriter.create(url: output, format: .tar)
            if mode == 0 { try BatchAdditionTestSupport.singles(writer, items) }
            else {
                var lastSize = 0
                try writer.add(items, events: mode == 1 ? nil : { event in
                    if case .didFinish = event {
                        let size = try Data(contentsOf: output).count
                        XCTAssertGreaterThan(size, lastSize)
                        lastSize = size
                    }
                })
                XCTAssertGreaterThan(try Data(contentsOf: output).count, 8 * 65_537)
            }
            try writer.finish()
            let bytes = try Data(contentsOf: output)
            if let baseline { XCTAssertEqual(bytes, baseline) } else { baseline = bytes }
            let expected = try items.map { ExpectedEntry(name: $0.path, data: try Data(contentsOf: $0.sourceURL!)) }
            try TestSupport.assertKaitoKitRoundTrip(output, expected: expected)
            try TestSupport.run(ReferenceTool.sevenZip, ["t", output.path], in: root, log: "7zz-\(mode)")
        }
    }

    func testDelayedWriteFailureBelongsToFirstUnwrittenAddition() throws {
        let root = try TestSupport.directory("r2-tar-buffer-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try BatchAdditionTestSupport.small(root, count: 8, size: 1_024)
        let output = root.appendingPathComponent("read-only.tar")
        try Data().write(to: output)
        let handle = try FileHandle(forReadingFrom: output)
        let tar = TarWriter(output: handle, url: output, compressor: nil)
        let writer = ArchiveWriter(output: handle, url: output, format: .tar,
                                   options: .init(compressionThreads: 4), tarWriter: tar)
        XCTAssertThrowsError(try writer.add(items, events: nil)) {
            let failure = $0 as? ArchiveAdditionError
            XCTAssertEqual(failure?.index, 0)
            XCTAssertEqual(failure?.path, items[0].path)
            XCTAssertEqual(failure?.sourceURL, items[0].sourceURL)
        }
        XCTAssertThrowsError(try writer.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
