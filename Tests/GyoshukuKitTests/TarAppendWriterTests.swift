import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

final class TarAppendWriterTests: XCTestCase {
    func testEndMembersAtNonzeroOffsetKeepsTailAndDescriptor() throws {
        let root = try ZipTestSupport.directory("p2-end-members")
        let output = root.appendingPathComponent("out.tar")
        let original = Data(repeating: 0x5a, count: 10240)
        try original.write(to: output)
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }
        let fd = dup(handle.fileDescriptor)
        let child = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let tar = TarWriter(output: child, url: output, compressor: nil, startPosition: 1024)
        var writer: ArchiveWriter? = ArchiveWriter(output: child, url: output, format: .tar,
                                                   options: .init(), tarWriter: tar)
        try writer!.prepareAppend(at: 1024, existingPaths: [])
        try writer!.add(data: Data([1]), as: "added", modificationDate: ZipTestSupport.date)
        XCTAssertEqual(try writer!.endAppendedMembers(), 2048)
        XCTAssertNotEqual(fcntl(fd, F_GETFD), -1)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, 10240)
        XCTAssertEqual(data.prefix(1024), original.prefix(1024))
        XCTAssertEqual(data.suffix(from: 2048), original.suffix(from: 2048))
        XCTAssertThrowsError(try writer!.addDirectory("late"))
        writer = nil
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        XCTAssertNotEqual(fcntl(handle.fileDescriptor, F_GETFD), -1)
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
}
