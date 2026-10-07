import Foundation
import KaitoKit
import XCTest

/// 形式に依らない test の共通部分：固定の更新日時、検証出力の directory、stderr への記録、外部ツールの検査付きの起動。
/// 形式ごとの照合（`verify`）と byte 検査器は `ZipTestSupport`・`TarTestSupport` などに置く。
///
/// `.build/verification/<label>` は試験の後も意図して残し、失敗したときに書庫と外部ツールの log を調べられるようにする
/// （同じ label の次の実行が `directory` で消す）。数十 MiB を超える出力は、その試験が成功後に自分で削除する。
enum TestSupport {
    /// fixture の entry に付ける更新日時。
    static let date = Date(timeIntervalSince1970: 1_700_000_001)

    /// 編集の試験が元書庫を読む設定。大きさの上限を外し、AppleDouble も通常の entry として見せる。
    static var editingReaderOptions: ReaderOptions {
        ReaderOptions(limits: .init(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose)
    }

    static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// `.build/verification/<label>` を空にして作り直す。
    static func directory(_ label: String) throws -> URL {
        let directory = TestPaths.verification.appendingPathComponent(label)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `root` の下に一度だけ使う作業 directory を作る。同じ試験の中で何度も独立に編集するときに使う。
    static func work(in root: URL) throws -> URL {
        let work = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// `allowed` 以外の終了値を失敗にし、出力を UTF-8 として返す。
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL, log: String,
                    allowed: Set<Int32> = [0]) throws -> String {
        let output = try ReferenceTool.run(tool, arguments, in: directory, log: log, expect: .oneOf(allowed))
        let text = output.utf8Text
        if tool.hasSuffix("/7zz") {
            // 7-Zip は Headers Error があっても exit 0 / Everything is Ok を返す場合がある。
            XCTAssertFalse(text.lowercased().contains("headers error") || text.lowercased().contains("warning") || text.lowercased().contains("errors:"), text)
        }
        report("REFERENCE \(directory.lastPathComponent)/\(log): exit \(output.status); \(text.split(separator: "\n").suffix(2).joined(separator: " | "))")
        return text
    }

    /// KaitoKit で書庫を開き、entry の名前の並びと、各 entry の種類・大きさ・permission・更新日時（`date` が nil でなければ）・
    /// 内容を照合する。形式ごとの検査（CRC、tar の uid、7z の solid など）は `extra` で同じ entry について行う。
    /// `comparesMetadata` が false なら大きさ・permission・更新日時を照合しない。
    @discardableResult
    static func assertKaitoKitRoundTrip(_ url: URL, expected: [ExpectedEntry], password: String? = nil,
                                        comparesMetadata: Bool = true,
                                        extra: (ArchiveEntry, ExpectedEntry) throws -> Void = { _, _ in }) throws -> ArchiveReader {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("decode.kaito-archive+compare", phaseStart, input: expected.reduce(0) { $0 + $1.data.count }) }
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), expected.map(\.name))
        guard reader.entries.count == expected.count else { return reader }
        for (entry, item) in zip(reader.entries, expected) {
            XCTAssertEqual(entry.kind, item.kind, item.name)
            if comparesMetadata {
                XCTAssertEqual(entry.uncompressedSize, UInt64(item.data.count), item.name)
                XCTAssertEqual(entry.posixPermissions, item.permissions, item.name)
                if let date = item.date { XCTAssertEqual(entry.modificationDate, date, item.name) }
            }
            XCTAssertEqual(try reader.read(entry), item.data, item.name)
            try extra(entry, item)
        }
        return reader
    }
}

/// 書いた書庫に期待する一つの entry。各 `*TestSupport` の `Expected`（暗号化は `Item`）はこの型の別名。
struct ExpectedEntry {
    var name: String
    var data = Data()
    var kind: EntryKind = .file
    var permissions: UInt16 = 0o644
    /// nil なら更新日時を照合しない。
    var date: Date? = TestSupport.date
    /// tar の symlink / hard link の参照先。
    var link: String? = nil
}
