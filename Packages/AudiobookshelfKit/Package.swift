// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudiobookshelfKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudiobookshelfKit", targets: ["AudiobookshelfKit"])
    ],
    targets: [
        // A client for Audiobookshelf's REST API, Foundation only, in the shape of OwnAudioKit.
        .target(name: "AudiobookshelfKit"),
        .testTarget(name: "AudiobookshelfKitTests", dependencies: ["AudiobookshelfKit"]),
    ]
)
