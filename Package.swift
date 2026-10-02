// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ghBonk",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ghBonk",
            path: "Sources"
        ),
        .testTarget(
            name: "ghBonkTests",
            dependencies: ["ghBonk"],
            path: "Tests"
        )
    ]
)
