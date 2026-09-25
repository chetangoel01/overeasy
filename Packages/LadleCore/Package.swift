// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LadleCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
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
