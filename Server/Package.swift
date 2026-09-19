// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "totem-server",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/vapor/redis.git", from: "4.10.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
        .package(path: "../TotemKit"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Redis", package: "redis"),
                .product(name: "VaporAPNS", package: "apns"),
                "TotemKit",
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "XCTVapor", package: "vapor"),
            ],
            path: "Tests/AppTests"
        ),
    ]
)
