// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WDSWhack",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "WDSWhackCore", targets: ["WDSWhackCore"]),
        .executable(name: "wds-whack", targets: ["WDSWhack"]),
    ],
    targets: [
        .target(
            name: "WDSWhackCore",
            path: "Sources/WDSWhackCore"
        ),
        .executableTarget(
            name: "WDSWhack",
            dependencies: ["WDSWhackCore"],
            path: "Sources/WDSWhack"
        ),
        .testTarget(
            name: "WDSWhackCoreTests",
            dependencies: ["WDSWhackCore"],
            path: "Tests/WDSWhackCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
