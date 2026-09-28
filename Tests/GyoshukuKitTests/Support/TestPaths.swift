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
    static let verification = package.appendingPathComponent(".build/verification")

    /// `Tests/Fixtures/<set>/<name>`。
    static func fixture(_ set: String, _ name: String) -> URL {
        fixtures.appendingPathComponent(set).appendingPathComponent(name)
    }
}
