// swift-tools-version: 6.0

import Foundation
import PackageDescription

// design.md §2: 開発中は隣接する ../KaitoKit の path 依存、release では tag 参照。
// 隣に KaitoKit の checkout があるときだけ path 依存にし、それ以外（利用側の SwiftPM 解決）は
// tag から取得する。切り替えた後は `swift package purge-cache`（Xcode は Reset Package Caches）で
// manifest を再評価させる。.build の削除では manifest cache が残る。
// KaitoKit の @_spi は SemVer の保証外で、公開 API にも KaitoKit の型を含むため、
// tag 依存は 0.13.x に限定する（0.13.0 以上、0.14.0 未満）。
let packageDirectory = URL(fileURLWithPath: Context.packageDirectory)
let siblingKaitoKit = packageDirectory.deletingLastPathComponent().appendingPathComponent("KaitoKit")
// SwiftPM / Xcode は依存を checkouts/ に並べて置くので、そこでは隣の KaitoKit を開発用の checkout と見なさない。
let isDependencyCheckout = packageDirectory.deletingLastPathComponent().lastPathComponent == "checkouts"
let kaitoKit: Package.Dependency =
    !isDependencyCheckout
        && FileManager.default.fileExists(atPath: siblingKaitoKit.appendingPathComponent("Package.swift").path)
        ? .package(path: "../KaitoKit")
        : .package(url: "https://github.com/shunnag/KaitoKit.git", .upToNextMinor(from: "0.13.0"))

let package = Package(
    name: "GyoshukuKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "GyoshukuKit", targets: ["GyoshukuKit"])],
    dependencies: [kaitoKit],
    targets: [
        .systemLibrary(name: "CGyoshukuBzip2"),
        .target(name: "GyoshukuKit", dependencies: ["CGyoshukuBzip2", .product(name: "KaitoKit", package: "KaitoKit")], linkerSettings: [.linkedLibrary("z")]),
        .testTarget(
            name: "GyoshukuKitTests",
            dependencies: ["GyoshukuKit", .product(name: "KaitoKit", package: "KaitoKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
