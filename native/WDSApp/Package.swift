// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WDSApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "WDSApp", targets: ["WDSApp"]),
    ],
    dependencies: [
        .package(path: "../Inertbox"),
        .package(path: "../WDSTerminalAdapter"),
        .package(path: "../WDSWhack"),
    ],
    targets: [
        .target(
            name: "WDSAppCore",
            dependencies: [
                .product(name: "Inertbox", package: "Inertbox"),
                .product(name: "WDSTerminalAdapterCore", package: "WDSTerminalAdapter"),
            ],
            path: "Sources/WDSAppCore"
        ),
        .executableTarget(
            name: "WDSApp",
            dependencies: [
                "WDSAppCore",
                .product(name: "Inertbox", package: "Inertbox"),
                .product(
                    name: "WDSTerminalAdapterCore",
                    package: "WDSTerminalAdapter"
                ),
                .product(
                    name: "WDSWhackCore",
                    package: "WDSWhack"
                ),
            ],
            path: "Sources/WDSApp"
        ),
        .testTarget(
            name: "WDSAppCoreTests",
            dependencies: ["WDSAppCore"],
            path: "Tests/WDSAppCoreTests"
        ),
    ]
)
