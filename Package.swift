// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-fileio",
    products: [
        .library(
            name: "FileIO",
            targets: ["FileIO"]
        ),
    ],
    targets: [
        .target(
            name: "FileIO"
        ),
        .testTarget(
            name: "FileIOTests",
            dependencies: ["FileIO"]
        ),
    ]
)
