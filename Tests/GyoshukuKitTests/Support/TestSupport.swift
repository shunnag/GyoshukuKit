import Foundation
import XCTest

/// 形式に依らない test の共通部分：固定の更新日時、検証出力の directory、stderr への記録、外部ツールの検査付きの起動。
/// 形式ごとの照合（`verify`）と byte 検査器は `ZipTestSupport`・`TarTestSupport` などに置く。
enum TestSupport {
    /// fixture の entry に付ける更新日時。
    static let date = Date(timeIntervalSince1970: 1_700_000_001)

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
}
