// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TotemKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TotemKit", targets: ["TotemKit"])
    ],
    targets: [
        .target(name: "TotemKit"),
        .testTarget(name: "TotemKitTests", dependencies: ["TotemKit"]),
    ]
)
