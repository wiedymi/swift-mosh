// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-mosh",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MoshCore", targets: ["MoshCore"]),
        .library(name: "MoshTransport", targets: ["MoshTransport"]),
        .library(name: "MoshWire", targets: ["MoshWire"]),
        .library(name: "MoshProtoLite", targets: ["MoshProtoLite"]),
        .library(name: "MoshCryptoOCB", targets: ["MoshCryptoOCB"]),
        .library(name: "MoshCompression", targets: ["MoshCompression"]),
        .library(name: "MoshBootstrap", targets: ["MoshBootstrap"])
    ],
    targets: [
        .target(name: "MoshWire"),
        .target(name: "MoshProtoLite"),
        .target(name: "MoshCryptoOCB"),
        .target(name: "MoshCompression"),
        .target(name: "MoshBootstrap"),
        .target(
            name: "MoshTransport",
            dependencies: ["MoshWire"]
        ),
        .target(
            name: "MoshCore",
            dependencies: [
                "MoshWire",
                "MoshTransport",
                "MoshProtoLite",
                "MoshCryptoOCB",
                "MoshCompression"
            ]
        ),
        .testTarget(
            name: "SwiftMoshTests",
            dependencies: [
                "MoshCore",
                "MoshTransport",
                "MoshWire",
                "MoshProtoLite",
                "MoshCryptoOCB",
                "MoshCompression",
                "MoshBootstrap"
            ],
            path: "Tests/SwiftMoshTests"
        )
    ]
)
