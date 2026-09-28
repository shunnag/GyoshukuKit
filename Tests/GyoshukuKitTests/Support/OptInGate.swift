import Foundation
import XCTest

/// 既定の `swift test` では走らせない試験（大きな入力・外部の corpus・計測）を環境変数で開ける門。
/// 鍵が無ければ `XCTSkip` で止め、理由は一つの文面 `Set <KEY>=<値> to run <class>; see Tests/README.md` にそろえる。
/// 鍵ごとの用途・必要な空き容量や build（`-c release -Xswiftc -enable-testing`）は Tests/README.md の表にある。
enum OptInGate {
    /// `key=1` のときだけ続ける。
    static func flag(_ key: String, fileID: String = #fileID) throws {
        guard isOn(key) else { throw skip(key, "1", fileID) }
    }

    /// `key` が `minimum` 以上の整数のときだけ続け、その値を返す。
    static func count(_ key: String, minimum: Int, fileID: String = #fileID) throws -> Int {
        guard let text = value(key), let count = Int(text), count >= minimum else {
            throw skip(key, "<count ≥ \(minimum)>", fileID)
        }
        return count
    }

    /// `key` に path があるときだけ続け、その URL を返す。
    static func path(_ key: String, fileID: String = #fileID) throws -> URL {
        guard let path = value(key) else { throw skip(key, "<path>", fileID) }
        return URL(fileURLWithPath: path)
    }

    // MARK: 門ではない設定（無くても試験は既定の値で走る）

    /// `key` の値。未設定なら nil。
    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// `key=1` か。
    static func isOn(_ key: String) -> Bool {
        value(key) == "1"
    }

    /// `key` の整数値。未設定か整数でなければ `defaultValue`。
    static func integer(_ key: String, default defaultValue: Int) -> Int {
        value(key).flatMap { Int($0) } ?? defaultValue
    }

    /// class 名は呼び出し元の file 名から取る（一 file に一つの XCTestCase で、file 名が class 名）。
    private static func skip(_ key: String, _ expected: String, _ fileID: String) -> XCTSkip {
        let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
        let testClass = file.hasSuffix(".swift") ? String(file.dropLast(".swift".count)) : file
        return XCTSkip("Set \(key)=\(expected) to run \(testClass); see Tests/README.md")
    }
}
