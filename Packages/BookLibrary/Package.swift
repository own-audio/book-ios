// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BookLibrary",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BookLibrary", targets: ["BookLibrary"])
    ],
    dependencies: [
        .package(path: "../AudiobookshelfKit"),
        .package(path: "../OwnAudioKit"),
        .package(path: "../ServerSupport"),
    ],
    targets: [
        // The app's only view of servers: one set of models, the `BookSource` interface with
        // what a server can do, one adapter per server kind, the server store and addresses.
        .target(name: "BookLibrary", dependencies: ["AudiobookshelfKit", "OwnAudioKit", "ServerSupport"]),
        .testTarget(name: "BookLibraryTests", dependencies: ["BookLibrary"]),
    ]
)
