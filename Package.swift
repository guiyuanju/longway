// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "longway",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LongwayCore", targets: ["LongwayCore"]),
        .executable(name: "longway", targets: ["LongwayCLI"])
    ],
    targets: [
        .target(name: "LongwayCore"),
        .executableTarget(
            name: "LongwayCLI",
            dependencies: ["LongwayCore"]
        ),
        .testTarget(
            name: "LongwayCoreTests",
            dependencies: ["LongwayCore"]
        )
    ]
)
