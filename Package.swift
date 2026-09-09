// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GyoshukuKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "GyoshukuKit", targets: ["GyoshukuKit"])],
    dependencies: [.package(path: "../KaitoKit")],
    targets: [
        .target(name: "GyoshukuKit", linkerSettings: [.linkedLibrary("z")]),
        .testTarget(
            name: "GyoshukuKitTests",
            dependencies: ["GyoshukuKit", .product(name: "KaitoKit", package: "KaitoKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
