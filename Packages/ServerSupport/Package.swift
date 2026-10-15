// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServerSupport",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ServerSupport", targets: ["ServerSupport"])
    ],
    targets: [
        .target(name: "ServerSupport"),
        .testTarget(name: "ServerSupportTests", dependencies: ["ServerSupport"]),
    ]
)
