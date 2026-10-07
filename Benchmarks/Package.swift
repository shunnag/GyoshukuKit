// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GyoshukuBenchmarks",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "gyoshuku-bench", targets: ["GyoshukuBench"]),
        .executable(name: "gyoshuku-multicore", targets: ["GyoshukuMulticore"])],
    dependencies: [.package(name: "GyoshukuKit", path: "../")],
    targets: [
        .executableTarget(name: "GyoshukuMulticore", dependencies: [.product(name: "GyoshukuKit", package: "GyoshukuKit")]),
        .executableTarget(
            name: "GyoshukuBench",
            dependencies: [.product(name: "GyoshukuKit", package: "GyoshukuKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
