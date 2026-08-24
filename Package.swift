// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FluentWorkIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FluentWorkCore",
            targets: ["FluentWorkCore"]
        ),
    ],
    targets: [
        .target(
            name: "FluentWorkCore",
            path: "Shared/FluentWorkCore"
        ),
        .testTarget(
            name: "FluentWorkCoreTests",
            dependencies: ["FluentWorkCore"],
            path: "Tests/FluentWorkCoreTests"
        ),
    ]
)
