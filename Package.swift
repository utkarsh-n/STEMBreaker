// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StemCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "StemCore", targets: ["StemCore"])],
    targets: [
        .target(name: "StemCore"),
        .testTarget(name: "StemCoreTests", dependencies: ["StemCore"])
    ]
)
