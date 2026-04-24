// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Limits",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Limits",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LimitsTests",
            dependencies: ["Limits"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
