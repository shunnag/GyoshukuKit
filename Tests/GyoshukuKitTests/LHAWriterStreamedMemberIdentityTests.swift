import CryptoKit
import Foundation
import XCTest
@testable import GyoshukuKit

// 1 MiB を超える member は LHAWriter.StreamedMember の経路（仮 header・raw の先書き・spool・header の確定）を通る。
// その出力 byte を逐次（threads 1）と並列（threads 4）で凍結する。LHAWriterParallelTests の直列参照は 1 MiB 以下の
// member だけを見るので、大きい member の byte 同一性はここで守る。
final class LHAWriterStreamedMemberIdentityTests: XCTestCase {
    func testStreamedMemberBytesAreFrozenAtEveryThreadCount() throws {
        let directory = try TestSupport.directory("lha-streamed-member-identity")
        // 圧縮できる text（3 MiB 超、-lh5-）と、縮まず全体を圧縮した後で -lh0- に落ちる乱数 2 本（1.5 MB と 2.6 MB）。
        var text = Data()
        var line = 0
        while text.count < 3 * 1024 * 1024 + 12_345 {
            text.append(contentsOf: Array("line \(line) の内容 lorem ipsum dolor sit amet \(line % 97) ".utf8))
            line += 1
        }
        let noise = LHATestSupport.random(1_500_000 + 7)
        var mixed = LHATestSupport.random(300_000)
        mixed.append(LHATestSupport.random(2_300_000))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // 分割前の 998536c の writer で書いた byte。threads に依らず同じ。
        let expected = "9298a24e2c4a736b6d78842e92c39bb18fc189ed655023eec5cfcf9db3d9c40c"
        for threads in [1, 4] {
            let url = directory.appendingPathComponent("streamed-\(threads).lzh")
            let writer = try ArchiveWriter.create(url: url, format: .lha, options: WriterOptions(compressionThreads: threads))
            try writer.addDirectory("dir", modificationDate: date, ownerIDs: nil)
            try writer.add(data: text, as: "dir/text.txt", modificationDate: date)
            try writer.add(data: noise, as: "noise.bin", modificationDate: date)
            try writer.add(data: mixed, as: "mixed.bin", modificationDate: date)
            try writer.add(data: Data("small".utf8), as: "small.txt", modificationDate: date)
            try writer.add(data: text, as: "text2.txt", modificationDate: date, permissions: 0o755)
            try writer.finish()
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(try LHABytes(bytes).members.map(\.method),
                           ["-lhd-", "-lh5-", "-lh0-", "-lh0-", "-lh0-", "-lh5-"], "threads=\(threads)")
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expected, "threads=\(threads)")
        }
    }
}
