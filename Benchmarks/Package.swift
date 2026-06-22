// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "FileIOBenchmarks",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "FileIOBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "FileIO", package: "swift-fileio"),
            ],
            path: "Benchmarks/FileIOBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark")
            ]
        )
    ]
)
