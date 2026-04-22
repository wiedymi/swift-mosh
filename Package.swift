// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-mosh",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftMosh", targets: ["SwiftMosh"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0")
    ],
    targets: [
        .target(
            name: "SwiftMosh",
            dependencies: [
                .product(name: "NIO", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "SwiftMoshTests",
            dependencies: ["SwiftMosh"],
            path: "Tests/SwiftMoshTests"
        )
    ]
)
