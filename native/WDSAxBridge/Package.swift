// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WDSAxBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "wds-ax-bridge", targets: ["WDSAxBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "WDSAxBridge",
            dependencies: ["WDSAxBridgeCore"]
        ),
        .target(name: "WDSAxBridgeCore"),
        .testTarget(
            name: "WDSAxBridgeTests",
            dependencies: ["WDSAxBridgeCore"]
        ),
    ]
)
