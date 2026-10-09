import Foundation
import CryptoKit
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class SevenZipWriterByteIdentityTests: XCTestCase {
    func testFrozenWriterBytes() throws {
        let directory = try TestSupport.directory("7z-frozen-writer")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "large")
        let times = [timeval(tv_sec: 1_700_000_001, tv_usec: 0), timeval(tv_sec: 1_700_000_001, tv_usec: 0)]
        XCTAssertEqual(lutimes(link.path, times), 0)
        XCTAssertEqual(lchmod(link.path, 0o755), 0)
        let block = Data((0..<65_536).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 7)) })
        var payload = Data()
        for _ in 0..<257 { payload.append(block) }
        // 6e7cd9b の writer。変更は IV の注入だけで、切り出し前に凍結した。
        let expected = [
            "62569437ffb3b10546cfd6c98ccdf394503cd66b666d9d7805d93bf3390384ef",
            "aa015767e4d16812f70fe66b3401b759cbfd291e78b1adde7be3236236fbbd4c",
            "789409389ca2ef9b2f3934dd224645ffdc418557e9d0b02898b2f382d1dd8a55"
        ]
        for mode in 0..<3 {
            for threads in [1, 8, 16] {
                let counter = Mutex<UInt8>(0)
                let url = directory.appendingPathComponent("\(mode)-\(threads).7z")
                try SevenZipAESEncryptor.$testingIV.withValue({
                    counter.withLock { value in value &+= 1; return Data(repeating: value, count: 16) }
                }) {
                    let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
                        options: WriterOptions(password: mode == 0 ? nil : "secret", encryptsSevenZipHeaders: mode == 2,
                                               compressionThreads: threads))
                    try writer.add(data: Data(), as: "empty", modificationDate: TestSupport.date)
                    try writer.addDirectory("directory", modificationDate: TestSupport.date, ownerIDs: nil)
                    try writer.add(contentsOf: link, as: "link")
                    try writer.add(data: payload, as: "large", modificationDate: TestSupport.date)
                    try writer.add(data: Data("日本語".utf8), as: "日本語", modificationDate: TestSupport.date)
                    try writer.finish()
                }
                let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(hash, expected[mode], "mode=\(mode), threads=\(threads)")
            }
        }
    }
    func testEmptyWriterBytesRemainUnchanged() throws {
        let root = try TestSupport.directory("7z-empty-writer-frozen")
        let output = root.appendingPathComponent("empty.7z")
        let writer = try ArchiveWriter.create(url: output, format: .sevenZip)
        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: SevenZipEditSupport.fixture("empty_gk")))
    }

}
