// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LadleCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "LadleCore", targets: ["LadleCore"]),
    ],
    targets: [
        .target(name: "LadleCore"),
        .testTarget(
            name: "LadleCoreTests",
            dependencies: ["LadleCore"]
        ),
    ]
)
