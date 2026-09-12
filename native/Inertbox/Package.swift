// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Inertbox",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Inertbox", targets: ["Inertbox"])],
    targets: [
        .target(name: "Inertbox"),
        .testTarget(name: "InertboxTests", dependencies: ["Inertbox"]),
    ]
)
