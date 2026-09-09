import Foundation
import KaitoKit
import XCTest

// 第三者実装の source を使わない、project-owned のクリーンルーム入力と byte 検査。
enum ZipTestSupport {
    static let date = Date(timeIntervalSince1970: 1_700_000_001)
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/verification")

    static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    struct Expected {
        var name: String
        var data = Data()
        var kind: EntryKind = .file
        var permissions: UInt16 = 0o644
        var date: Date = ZipTestSupport.date
    }

    static func directory(_ label: String) throws -> URL {
        let directory = root.appendingPathComponent(label)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL, log: String,
                    allowed: Set<Int32> = [0]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            XCTFail("Required reference tool missing: \(tool)")
            throw CocoaError(.fileNoSuchFile)
        }
        let output = directory.appendingPathComponent(log + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        try handle.close()
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        XCTAssertTrue(allowed.contains(process.terminationStatus), "\(tool) \(arguments) exit \(process.terminationStatus): \(text.prefix(4000))")
        if tool.hasSuffix("/7zz") {
            // 7-Zip は Headers Error があっても exit 0 / Everything is Ok を返す場合がある。
            XCTAssertFalse(text.contains("Headers Error") || text.lowercased().contains("warnings:") || text.lowercased().contains("errors:"), text)
        }
        report("REFERENCE \(directory.lastPathComponent)/\(log): exit \(process.terminationStatus); \(text.split(separator: "\n").suffix(2).joined(separator: " | "))")
        return text
    }

    /// 全書庫を実ツールで検査し、展開結果と KaitoKit の全 entry を照合する。
    static func verify(_ archive: URL, expected: [Expected]) throws {
        let directory = archive.deletingLastPathComponent()
        let empty = expected.isEmpty
        let test = try run("/usr/bin/unzip", ["-t", archive.path], in: directory, log: "unzip-t", allowed: empty ? [1] : [0])
        if empty { XCTAssertTrue(test.contains("zipfile is empty")) }
        else { XCTAssertTrue(test.contains("No errors detected")) }
        let listing = try run("/usr/bin/unzip", ["-l", archive.path], in: directory, log: "unzip-l", allowed: empty ? [1] : [0])
        func names(in listing: String) -> [String] { listing.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, UInt64(fields[0]) != nil, fields[1].contains("-") else { return nil }
            return String(fields[3]).trimmingCharacters(in: .whitespaces)
        } }
        if expected.contains(where: { !$0.name.utf8.allSatisfy({ $0 < 128 }) }) {
            // Apple 版 unzip は Unicode 非対応 build。独立した標準 ZIP と表示を比較する。
            let oracle = directory.appendingPathComponent("python-oracle.zip")
            try run("/usr/bin/python3", ["-c", "import sys,zipfile,unicodedata; z=zipfile.ZipFile(sys.argv[1],'w'); [z.writestr(unicodedata.normalize('NFC',n),b'') for n in sys.argv[2:]]; z.close()", oracle.path] + expected.map(\.name), in: directory, log: "python-create")
            let oracleListing = try run("/usr/bin/unzip", ["-l", oracle.path], in: directory, log: "python-unzip-l")
            XCTAssertEqual(names(in: listing), names(in: oracleListing))
        } else {
            XCTAssertEqual(names(in: listing), expected.map(\.name))
        }
        let seven = try run("/opt/homebrew/bin/7zz", ["t", archive.path], in: directory, log: "7zz-t")
        XCTAssertTrue(seven.contains("Everything is Ok"))
        let sevenListing = try run("/opt/homebrew/bin/7zz", ["l", "-slt", archive.path], in: directory, log: "7zz-l")
        let sevenNames = sevenListing.components(separatedBy: "----------\n").last!
            .split(separator: "\n").filter { $0.hasPrefix("Path = ") }.map { String($0.dropFirst(7)) }
        XCTAssertEqual(sevenNames, expected.map { $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name })
        let extracted = directory.appendingPathComponent("ditto")
        let ditto = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], in: directory, log: "ditto-x", allowed: empty ? [1] : [0])
        if empty {
            // EOCD だけの正当な空 ZIP も ditto は拒否する。結果を成功と偽らない。
            XCTAssertEqual(ditto, "ditto: Incorrect pkzip signature\n")
        }
        _ = try run("/usr/bin/tar", ["-tf", archive.path], in: directory, log: "bsdtar-t")
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), expected.map(\.name))
        guard reader.entries.count == expected.count else { return }
        for (entry, item) in zip(reader.entries, expected) {
            XCTAssertEqual(entry.kind, item.kind, item.name)
            XCTAssertEqual(entry.posixPermissions, item.permissions, item.name)
            XCTAssertEqual(entry.modificationDate, item.date, item.name)
            XCTAssertEqual(entry.crc32, CRC32.checksum(item.data), item.name)
            XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), item.name)
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
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
    func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }
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
