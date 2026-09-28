import Darwin
import Foundation
import XCTest
@testable import GyoshukuKit

final class FileReadTests: XCTestCase {
    func testShortReadReturnsAvailableBytesAndThenEOF() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        defer { try? pipe.fileHandleForWriting.close() }
        let payload = Data("short read".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        let fd = pipe.fileHandleForReading.fileDescriptor
        XCTAssertEqual(try FileRead.readChunk(fd, upTo: 256 * 1024), payload)
        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(try FileRead.readChunk(fd, upTo: 1).isEmpty)
    }

    func testInvalidDescriptorThrowsWriterIOError() {
        XCTAssertThrowsError(try FileRead.readChunk(-1, upTo: 1)) {
            XCTAssertEqual($0 as? WriterError, .io(operation: "read", code: EBADF))
        }
    }
}
