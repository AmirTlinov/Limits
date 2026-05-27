// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Limits",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Limits", targets: ["Limits"]),
        .executable(name: "LimitsWidgetExtension", targets: ["LimitsWidgetExtension"]),
        .library(name: "LimitsShared", targets: ["LimitsShared"]),
    ],
    targets: [
        .target(
            name: "LimitsShared"
        ),
        .executableTarget(
            name: "Limits",
            dependencies: ["LimitsShared"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "LimitsWidgetExtension",
            dependencies: ["LimitsShared"]
        ),
        .testTarget(
            name: "LimitsTests",
            dependencies: ["Limits", "LimitsShared"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
