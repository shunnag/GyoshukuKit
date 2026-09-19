// swift-tools-version: 6.0

import Foundation
import PackageDescription

// design.md §2: 開発中は隣接する ../KaitoKit の path 依存、release では tag 参照。
// 隣に KaitoKit の checkout があるときだけ path 依存にし、それ以外（利用側の SwiftPM 解決）は
// tag から取得する。切り替えた後は .build / DerivedData を消して manifest を再評価させる。
let siblingKaitoKit = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent().appendingPathComponent("KaitoKit")
let kaitoKit: Package.Dependency =
    FileManager.default.fileExists(atPath: siblingKaitoKit.appendingPathComponent("Package.swift").path)
        ? .package(path: "../KaitoKit")
        : .package(url: "https://github.com/shunnag/KaitoKit.git", from: "0.7.0")

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
