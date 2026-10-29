import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

final class BatchWriteFailureAttributionTests: XCTestCase {
    private func sources(_ root: URL) throws -> [ArchiveAddition] {
        try ["a.bin", "c.bin"].map { name in
            let url = root.appendingPathComponent(name)
            try Data(repeating: 65, count: 4_000).write(to: url)
            return ArchiveAddition(path: name, source: .contents(of: url))
        }
    }

    // Keep FileHandle alive while replacing its output descriptor, as in ReviewFixAttributionTests.
    private func makeReadOnly(_ output: URL, handle: FileHandle) throws {
        let descriptor = Darwin.open(output.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw WriterError.io(operation: "test open", code: errno) }
        defer { Darwin.close(descriptor) }
        guard dup2(descriptor, handle.fileDescriptor) == handle.fileDescriptor else {
            throw WriterError.io(operation: "test dup2", code: errno)
        }
    }

    private func assertFirstWriteFailure(_ error: Error, first: ArchiveAddition,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? ArchiveAdditionError else {
            return XCTFail("Expected ArchiveAdditionError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(failure.index, 0, file: file, line: line)
        XCTAssertEqual(failure.path, first.path, file: file, line: line)
        XCTAssertEqual(failure.sourceURL, first.sourceURL, file: file, line: line)
        XCTAssertEqual((failure.underlying as NSError).domain, NSCocoaErrorDomain, file: file, line: line)
    }

    func testTarPerItemPrefixKeepsFirstBatchWriteFailureAttribution() throws {
        let root = try TestSupport.directory("r2-tar-prefix-attribution")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try sources(root)
        for missing in [false, true] {
            let output = root.appendingPathComponent("\(missing).tar")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            let tar = TarWriter(output: handle, url: output, compressor: nil)
            let writer = ArchiveWriter(output: handle, url: output, format: .tar,
                                       options: .init(compressionThreads: 4), tarWriter: tar)
            try writer.add(data: Data([1]), as: "prefix.bin", modificationDate: TestSupport.date)
            try makeReadOnly(output, handle: handle)
            let second = missing ? ArchiveAddition(path: "missing.bin", source: .contents(of: root.appendingPathComponent("missing.bin"))) : items[1]
            XCTAssertThrowsError(try writer.add([items[0], second], events: nil)) {
                self.assertFirstWriteFailure($0, first: items[0])
            }
            XCTAssertThrowsError(try writer.finish())
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testSevenZipPrefetchedWriteFailureBeatsLaterPreparationFailure() throws {
        try checkSevenZipFailure(readFailure: false)
    }

    func testSevenZipPendingWriteFailureBeatsLaterPrefetchReadFailure() throws {
        try checkSevenZipFailure(readFailure: true)
    }

    private func checkSevenZipFailure(readFailure: Bool) throws {
        let root = try TestSupport.directory("r2-sevenzip-prefetch-attribution-\(readFailure)")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try sources(root)
        for method: SevenZipCompressionMethod in [.lzma, .ppmd] {
            let output = root.appendingPathComponent("\(method).7z")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            let options = WriterOptions(sevenZipMethod: method, ppmdMemoryMiB: 1,
                                        lzmaLevel: 0, compressionThreads: 4)
            let seven = try SevenZipWriter(output: handle, url: output, options: options)
            let writer = ArchiveWriter(output: handle, url: output, format: .sevenZip,
                                       options: options, sevenZipWriter: seven)
            // Reserve the signature successfully so the later failure is deferred payload output.
            try writer.add(data: Data(), as: "prefix", modificationDate: TestSupport.date)
            XCTAssertEqual(try handle.offset(), 32)
            try makeReadOnly(output, handle: handle)
            let second = readFailure ? items[1]
                : ArchiveAddition(path: "missing.bin", source: .contents(of: root.appendingPathComponent("missing.bin")))
            try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in
                if readFailure && index == 1 { throw WriterError.io(operation: "test read", code: EIO) }
            }) {
                XCTAssertThrowsError(try writer.add([items[0], second], events: nil)) {
                    self.assertFirstWriteFailure($0, first: items[0])
                }
            }
            XCTAssertThrowsError(try writer.finish())
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
