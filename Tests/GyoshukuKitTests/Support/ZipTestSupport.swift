import Foundation
import KaitoKit
import XCTest

// 第三者実装の source を使わない、project-owned のクリーンルーム入力と byte 検査。
enum ZipTestSupport {
    typealias Expected = ExpectedEntry

    /// 全書庫を実ツールで検査し、展開結果と KaitoKit の全 entry を照合する。
    static func verify(_ archive: URL, expected: [Expected], legacyCP932: Bool = false,
                       legacyOriginalIndices: [Int] = [0]) throws {
        let directory = archive.deletingLastPathComponent()
        let empty = expected.isEmpty
        let test = try TestSupport.run(ReferenceTool.unzip, ["-t", archive.path], in: directory, log: "unzip-t", allowed: empty ? [1] : [0])
        if empty { XCTAssertTrue(test.contains("zipfile is empty")) }
        else { XCTAssertTrue(test.contains("No errors detected")) }
        let listing = try TestSupport.run(ReferenceTool.unzip, ["-l", archive.path], in: directory, log: "unzip-l", allowed: empty ? [1] : [0])
        func names(in listing: String) -> [String] { listing.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, UInt64(fields[0]) != nil, fields[1].contains("-") else { return nil }
            return String(fields[3]).trimmingCharacters(in: .whitespaces)
        } }
        if legacyCP932 {
            // Apple unzip の非 Unicode 表示は byte 保存の検査と分ける。
            XCTAssertEqual(names(in: listing).count, expected.count)
        } else if expected.contains(where: { !$0.name.utf8.allSatisfy({ $0 < 128 }) }) {
            // Apple 版 unzip は Unicode 非対応 build。独立した標準 ZIP と表示を比較する。
            let oracle = directory.appendingPathComponent("python-oracle.zip")
            try TestSupport.run(ReferenceTool.python3, ["-c", "import sys,zipfile,unicodedata; z=zipfile.ZipFile(sys.argv[1],'w'); [z.writestr(unicodedata.normalize('NFC',n),b'') for n in sys.argv[2:]]; z.close()", oracle.path] + expected.map(\.name), in: directory, log: "python-create")
            let oracleListing = try TestSupport.run(ReferenceTool.unzip, ["-l", oracle.path], in: directory, log: "python-unzip-l")
            XCTAssertEqual(names(in: listing), names(in: oracleListing))
        } else {
            XCTAssertEqual(names(in: listing), expected.map(\.name))
        }
        let seven = try TestSupport.run(ReferenceTool.sevenZip, ["t"] + (legacyCP932 ? ["-mcp=932"] : []) + [archive.path], in: directory, log: "7zz-t")
        XCTAssertTrue(seven.contains("Everything is Ok"))
        let sevenListing = try TestSupport.run(ReferenceTool.sevenZip, ["l", "-slt"] + (legacyCP932 ? ["-mcp=932"] : []) + [archive.path], in: directory, log: "7zz-l")
        let sevenNames = sevenListing.components(separatedBy: "----------\n").last!
            .split(separator: "\n").filter { $0.hasPrefix("Path = ") }.map { String($0.dropFirst(7)) }
        if legacyCP932 {
            // macOS 版 7zz の CP932 表示は独立 fixture の更新前と比較する。
            // 正しい日本語名そのものは下の KaitoKit と ditto で必ず照合する。
            let baseline = try String(contentsOf: directory.appendingPathComponent("original-7zz-l.log"), encoding: .utf8)
            let originalNames = baseline.components(separatedBy: "----------\n").last!
                .split(separator: "\n").filter { $0.hasPrefix("Path = ") }.map { String($0.dropFirst(7)) }
            XCTAssertTrue(legacyOriginalIndices.allSatisfy { originalNames.indices.contains($0) })
            XCTAssertEqual(sevenNames, legacyOriginalIndices.map { originalNames[$0] }
                           + expected.dropFirst(legacyOriginalIndices.count).map(\.name))
        } else {
            XCTAssertEqual(sevenNames, expected.map { $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name })
        }
        let extracted = directory.appendingPathComponent("ditto")
        let ditto = try TestSupport.run(ReferenceTool.ditto, ["-x", "-k", archive.path, extracted.path], in: directory, log: "ditto-x", allowed: empty ? [1] : [0])
        if empty {
            // EOCD だけの正当な空 ZIP も ditto は拒否する。結果を成功と偽らない。
            XCTAssertEqual(ditto, "ditto: Incorrect pkzip signature\n")
        }
        _ = try TestSupport.run(ReferenceTool.tar, ["-tf", archive.path], in: directory, log: "bsdtar-t")
        try TestSupport.assertKaitoKitRoundTrip(archive, expected: expected) { entry, item in
            XCTAssertEqual(entry.crc32, CRC32.checksum(item.data), item.name)
            let file = extracted.appendingPathComponent(item.name)
            switch item.kind {
            case .file:
                XCTAssertEqual(try Data(contentsOf: file), item.data, item.name)
            case .symlink:
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), String(decoding: item.data, as: UTF8.self))
            case .directory:
                var isDirectory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
                XCTAssertTrue(isDirectory.boolValue)
            default: XCTFail("unexpected fixture kind")
            }
        }
    }
}

// 公開 ZIP byte 表に基づく検査器。製品の serializer を oracle にしない。
struct ZipBytes {
    let data: Data
    func u16(_ offset: Int) -> UInt16 { data.testUInt16(at: offset) }
    func u32(_ offset: Int) -> UInt32 { data.testUInt32(at: offset) }
    func u64(_ offset: Int) -> UInt64 { data.testUInt64(at: offset) }
    var end: Int { data.count - 22 }
    var central: Int {
        if u32(end + 16) == UInt32.max {
            return Int(u64(Int(u64(end - 12)) + 48))
        }
        return Int(u32(end + 16))
    }
    func extras(_ offset: Int, local: Bool) -> [UInt16: Data] {
        let fixed = local ? 30 : 46
        let nameLength = Int(u16(offset + (local ? 26 : 28)))
        let extraLength = Int(u16(offset + (local ? 28 : 30)))
        var cursor = offset + fixed + nameLength
        let end = cursor + extraLength
        var fields: [UInt16: Data] = [:]
        while cursor < end {
            let length = Int(u16(cursor + 2))
            fields[u16(cursor)] = data.subdata(in: (cursor + 4)..<(cursor + 4 + length))
            cursor += 4 + length
        }
        return fields
    }
}
