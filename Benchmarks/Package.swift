// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GyoshukuBenchmarks",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "gyoshuku-bench", targets: ["GyoshukuBench"])],
    dependencies: [.package(path: "../")],
    targets: [
        .executableTarget(
            name: "GyoshukuBench",
            dependencies: [.product(name: "GyoshukuKit", package: "GyoshukuKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
