import Foundation
import XCTest

/// 書いた書庫を製品の実装とは別に読み直す外部ツールの path と、その起動。
/// ツールが無ければ失敗する。名前に `WhenAvailable` を含む試験だけ `optional` で skip を許す。
/// Homebrew の参照ツールは CI で導入し、OS の参照ツールは macOS 同梱のものを使う。
/// 形式ごとの出力の検査（7-Zip の "Everything is Ok"、Lhasa の "Tested" など）は各 `*TestSupport` の wrapper に置く。
enum ReferenceTool {
    static let sevenZip = "/opt/homebrew/bin/7zz"
    static let lhasa = "/opt/homebrew/bin/lha"
    static let xz = "/opt/homebrew/bin/xz"
    static let zstd = "/opt/homebrew/bin/zstd"
    static let lzip = "/opt/homebrew/bin/lzip"

    static let bsdtar = "/usr/bin/bsdtar"
    /// `bsdtar` への symlink。argv[0] で診断の接頭辞（`tar:` / `bsdtar:`）が変わるので、別の名前として残す。
    static let tar = "/usr/bin/tar"
    static let unzip = "/usr/bin/unzip"
    static let zip = "/usr/bin/zip"
    static let ditto = "/usr/bin/ditto"
    static let gzip = "/usr/bin/gzip"
    static let bzip2 = "/usr/bin/bzip2"
    static let python3 = "/usr/bin/python3"
    static let xattr = "/usr/bin/xattr"
    static let cmp = "/usr/bin/cmp"
    static let git = "/usr/bin/git"
    static let hdiutil = "/usr/bin/hdiutil"

    /// 出力の言語と文字コードを固定する。`run` の既定。
    static let englishUTF8 = ["LC_ALL": "en_US.UTF-8"]
    /// 7-Zip / Lhasa の一覧の時刻を UTC で表示させ、書いた時刻と文字列で照合する。
    static let englishUTF8InUTC = ["LC_ALL": "en_US.UTF-8", "TZ": "UTC"]

    enum ExitExpectation {
        case success
        case failure
        case oneOf(Set<Int32>)
        /// 呼び出し側が status を判断する。
        case unchecked
    }

    struct Output {
        /// stdout と stderr。`standardOutput` を指定したときは stdout だけ。
        let bytes: Data
        let status: Int32
        /// UTF-8 として読む。不正な byte は U+FFFD にする。
        var utf8Text: String { String(decoding: bytes, as: UTF8.self) }
        /// UTF-8、Shift-JIS の順に読む。Lhasa などは CP932 の名前を変換せずに出力する。
        var text: String {
            String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .shiftJIS) ?? utf8Text
        }
    }

    /// `tool` を起動して終了を待つ。ツールが無ければ XCTFail して throw する（skip にしない）。
    /// - stdout と stderr は `directory/<log>.log` に書き、`.build/verification` に残して失敗の調査に使う。
    ///   `standardOutput` を指定すると stdout だけを `directory/<standardOutput>` に分ける。
    /// - `environment` は実行中の環境変数への上書き。`[:]` は test process の環境をそのまま渡す。
    /// - `stdin` が nil なら test process の標準入力を引き継ぐ。password prompt を EOF で終わらせるには `.nullDevice`。
    /// - `workingDirectory` が nil なら test process の current directory を引き継ぐ。
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL, log: String,
                    expect: ExitExpectation = .success, stdin: FileHandle? = nil,
                    environment extra: [String: String] = englishUTF8,
                    workingDirectory: URL? = nil, standardOutput: String? = nil) throws -> Output {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("oracle.process+files", phaseStart, input: 0) }
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            XCTFail("Required reference tool missing: \(tool)")
            throw CocoaError(.fileNoSuchFile)
        }
        let logURL = directory.appendingPathComponent(log + ".log")
        let outputURL = standardOutput.map { directory.appendingPathComponent($0) } ?? logURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if outputURL != logURL { FileManager.default.createFile(atPath: outputURL.path, contents: nil) }
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }
        let outputHandle = outputURL == logURL ? logHandle : try FileHandle(forWritingTo: outputURL)
        defer { if outputHandle !== logHandle { try? outputHandle.close() } }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let stdin { process.standardInput = stdin }
        process.standardOutput = outputHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        if tool == ditto {
            // ditto は UTF-8 の flag のない名前をまず UTF-8 として読み、UTF-8 として不正な byte（CP932 など）だけを
            // 利用者の既定の文字コード（~/.CFUserTextEncoding）で解釈する。CP932 の名前の試験を実行環境の言語設定に
            // 依存させないよう、日本語（MacJapanese、地域 Japan）を明示する。
            environment["__CF_USER_TEXT_ENCODING"] = String(format: "0x%X:0x1:0xE", getuid())
        }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = Output(bytes: try Data(contentsOf: outputURL), status: process.terminationStatus)
        let diagnostic = outputURL == logURL ? output.utf8Text : String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        let message = "\(tool) \(arguments) exit \(output.status): \(diagnostic.prefix(4000))"
        switch expect {
        case .success: XCTAssertEqual(output.status, 0, message)
        case .failure: XCTAssertNotEqual(output.status, 0, message)
        case .oneOf(let allowed): XCTAssertTrue(allowed.contains(output.status), message)
        case .unchecked: break
        }
        return output
    }

    /// 候補の path のうち最初に実行できるもの。どれも無ければ XCTFail して throw する。
    static func require(_ candidates: [String]) throws -> String {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            XCTFail("Required reference tool missing: \(candidates.joined(separator: ", "))")
            throw CocoaError(.fileNoSuchFile)
        }
        return path
    }

    /// `WhenAvailable` の試験用。候補の path がどれも実行できなければ skip する。
    static func optional(_ candidates: [String]) throws -> String {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Reference tool missing: \(candidates.joined(separator: ", "))")
        }
        return path
    }
}
