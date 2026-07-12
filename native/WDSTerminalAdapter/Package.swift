// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WDSTerminalAdapter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "WDSTerminalAdapterCore",
            targets: ["WDSTerminalAdapterCore"]
        ),
        .executable(
            name: "wds-terminal-adapter",
            targets: ["WDSTerminalAdapter"]
        ),
    ],
    targets: [
        .target(name: "WDSTerminalAdapterCore"),
        .executableTarget(
            name: "WDSTerminalAdapter",
            dependencies: ["WDSTerminalAdapterCore"]
        ),
        .testTarget(
            name: "WDSTerminalAdapterCoreTests",
            dependencies: ["WDSTerminalAdapterCore"]
        ),
    ]
)
