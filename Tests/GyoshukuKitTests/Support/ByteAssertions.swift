import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

/// 二つの file を 4 MiB ずつ比べ、最初に違う chunk の位置を報告する。数十 MiB の書庫を二つとも丸ごと読まない。
func XCTAssertFilesEqual(_ left: URL, _ right: URL, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try FileHandle(forReadingFrom: left), b = try FileHandle(forReadingFrom: right)
    defer { try? a.close(); try? b.close() }
    var offset: UInt64 = 0
    while true {
        let x = try a.read(upToCount: 4 * 1024 * 1024) ?? Data()
        let y = try b.read(upToCount: 4 * 1024 * 1024) ?? Data()
        guard x == y else { XCTFail("\(message): byte mismatch at chunk \(offset)", file: file, line: line); return }
        if x.isEmpty { return }
        offset += UInt64(x.count)
    }
}

/// 二つの ByteSource（圧縮 tar の展開 image など）を 1 MiB ずつ比べる。
func XCTAssertByteSourcesEqual(_ left: any ByteSource, _ right: any ByteSource,
                               file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(left.length, right.length, file: file, line: line)
    guard left.length == right.length else { return }
    var offset: UInt64 = 0
    while offset < left.length {
        let count = Int(min(1048576, left.length - offset))
        XCTAssertEqual(try TarLayout.bytes(left, at: offset, count: count), try TarLayout.bytes(right, at: offset, count: count),
                       "image at \(offset)", file: file, line: line)
        offset += UInt64(count)
    }
}
