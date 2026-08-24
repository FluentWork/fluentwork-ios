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
    dependencies: [
        .package(url: "https://github.com/tangzzz-fan/TGReduxKit.git", exact: "4.0.0"),
        .package(url: "https://github.com/hmlongco/Factory.git", exact: "3.3.2"),
        .package(url: "https://github.com/Moya/Moya.git", exact: "15.0.3"),
    ],
    targets: [
        .target(
            name: "FluentWorkFeatureFlags",
            dependencies: ["TGReduxKit"],
            path: "Shared/FluentWorkFeatureFlags"
        ),
        .target(
            name: "FluentWorkPluginSupport",
            dependencies: ["FluentWorkFeatureFlags"],
            path: "Shared/FluentWorkPluginSupport"
        ),
        .target(
            name: "FluentWorkNetworking",
            dependencies: [
                .product(name: "Moya", package: "Moya"),
            ],
            path: "Shared/FluentWorkNetworking"
        ),
        .target(
            name: "FluentWorkCore",
            dependencies: [
                "TGReduxKit",
                .product(name: "FactoryKit", package: "Factory"),
                "FluentWorkFeatureFlags",
                "FluentWorkPluginSupport",
                "FluentWorkNetworking",
            ],
            path: "Shared/FluentWorkCore"
        ),
        .testTarget(
            name: "FluentWorkCoreTests",
            dependencies: [
                "FluentWorkCore",
                "FluentWorkFeatureFlags",
                "FluentWorkPluginSupport",
                "TGReduxKit",
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/FluentWorkCoreTests"
        ),
    ]
)
