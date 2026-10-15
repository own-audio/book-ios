// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "player-engine",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // The parts every kind of player shares: Now Playing, sleep timer, resume points, the
        // file cache. Copied from own.audio Music; the spoken-word engine (B3) builds on it.
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        // What the app imports to play books: an AVPlayer over a book's files as one timeline,
        // speed with pitch correction, chapters, skips, smart rewind, the sleep timer.
        .library(name: "SpokenEngine", targets: ["SpokenEngine"]),
    ],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "SpokenEngine", dependencies: ["PlayerCore"]),
        .testTarget(
            name: "PlayerEngineTests",
            dependencies: ["PlayerCore", "SpokenEngine"],
            // Short synthesized tones, so payload checks run against real audio bytes.
            resources: [.copy("Fixtures")]
        ),
    ]
)
