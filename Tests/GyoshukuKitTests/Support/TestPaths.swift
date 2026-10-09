import Foundation

/// test が読む fixture と書く検証出力の場所。この file の位置（`Tests/GyoshukuKitTests/Support/`）からだけ計算し、
/// test file や helper を別の directory へ移しても参照先が変わらないようにする。
/// `Tests/Fixtures` は SwiftPM の resource bundle ではない（Package.swift は resources を宣言しない）ので、
/// source tree の path を直接読む。
enum TestPaths {
    /// Package.swift のある directory。
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // GyoshukuKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent()
    static let fixtures = package.appendingPathComponent("Tests/Fixtures")
    /// 検証の出力を置く root。Xcode が再帰的に同期する package の group の外に置く。
    static let verification: URL = {
        let base = package.appendingPathComponent(".build/verification")
        // SwiftPMの並列試験は別processで動く。共有labelのfixtureを互いに消さない。
        if OptInGate.isOn("GYOSHUKU_TEST_PROCESS_DIRECTORY") {
            return base.appendingPathComponent("parallel").appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier))
        }
        guard let run = OptInGate.value("GYOSHUKU_ENCODER_BENCHMARK_RUN"), !run.isEmpty else { return base }
        // 同じ class を複数 process で計測しても、一時 file を共有しない。
        return base.appendingPathComponent("encoder-speed").appendingPathComponent(URL(fileURLWithPath: run).lastPathComponent)
    }()

    /// `Tests/Fixtures/<set>/<name>`。
    static func fixture(_ set: String, _ name: String) -> URL {
        fixtures.appendingPathComponent(set).appendingPathComponent(name)
    }
}
