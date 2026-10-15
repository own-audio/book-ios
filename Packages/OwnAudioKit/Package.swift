// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OwnAudioKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OwnAudioKit", targets: ["OwnAudioKit"])
    ],
    targets: [
        // A client for own.audio's own API (`/api/v2`), Foundation only, like SubsonicKit and JellyfinKit.
        .target(name: "OwnAudioKit"),
        .testTarget(name: "OwnAudioKitTests", dependencies: ["OwnAudioKit"]),
    ]
)
