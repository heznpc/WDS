// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WDSSensor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "wds-sensor", targets: ["WDSSensor"]),
        .library(name: "WDSSensorCore", targets: ["WDSSensorCore"]),
    ],
    targets: [
        .target(name: "WDSSensorCore"),
        .executableTarget(
            name: "WDSSensor",
            dependencies: ["WDSSensorCore"]
        ),
        .testTarget(
            name: "WDSSensorCoreTests",
            dependencies: ["WDSSensorCore"]
        ),
    ]
)
