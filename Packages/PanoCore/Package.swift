// swift-tools-version:5.9
import PackageDescription

// Platform-free stitching core: no Apple frameworks, so it builds and tests on Linux.
let package = Package(
    name: "PanoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PanoCore", targets: ["PanoCore"]),
    ],
    targets: [
        .target(name: "PanoCore"),
        .testTarget(name: "PanoCoreTests", dependencies: ["PanoCore"]),
    ]
)
