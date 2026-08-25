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
        .library(
            name: "FluentWorkDiagnostics",
            targets: ["FluentWorkDiagnostics"]
        ),
        .library(
            name: "FluentWorkUI",
            targets: ["FluentWorkUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tangzzz-fan/TGReduxKit.git", from: "5.0.1"),
        .package(url: "https://github.com/hmlongco/Factory.git", exact: "3.3.2"),
        .package(url: "https://github.com/tangzzz-fan/Moya.git", branch: "master"),
        .package(url: "https://github.com/tangzzz-fan/TGNavigationStack.git", from: "1.1.0"),
        .package(url: "https://github.com/tangzzz-fan/TGFeatureFlag.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "FluentWorkFeatureFlags",
            dependencies: [
                .product(name: "TGReduxKit", package: "TGReduxKit"),
                .product(name: "TGFeatureFlag", package: "TGFeatureFlag"),
            ],
            path: "Shared/FluentWorkFeatureFlags"
        ),
        .target(
            name: "FluentWorkPluginSupport",
            dependencies: ["FluentWorkFeatureFlags"],
            path: "Shared/FluentWorkPluginSupport"
        ),
        .target(
            name: "FluentWorkDiagnostics",
            dependencies: [],
            path: "Shared/FluentWorkDiagnostics"
        ),
        .target(
            name: "FluentWorkNetworking",
            dependencies: [
                .product(name: "Moya", package: "Moya"),
            ],
            path: "Shared/FluentWorkNetworking"
        ),
        .target(
            name: "FluentWorkUI",
            dependencies: [],
            path: "Shared/FluentWorkUI"
        ),
        .target(
            name: "FluentWorkCore",
            dependencies: [
                .product(name: "TGReduxKit", package: "TGReduxKit"),
                .product(name: "FactoryKit", package: "Factory"),
                .product(name: "TGNavigationStack", package: "TGNavigationStack"),
                "FluentWorkFeatureFlags",
                "FluentWorkPluginSupport",
                "FluentWorkNetworking",
                "FluentWorkDiagnostics",
            ],
            path: "Shared/FluentWorkCore"
        ),
        .testTarget(
            name: "FluentWorkCoreTests",
            dependencies: [
                "FluentWorkCore",
                "FluentWorkFeatureFlags",
                "FluentWorkPluginSupport",
                "FluentWorkDiagnostics",
                "FluentWorkNetworking",
                "FluentWorkUI",
                .product(name: "TGReduxKit", package: "TGReduxKit"),
                .product(name: "TGReduxKitTesting", package: "TGReduxKit"),
                .product(name: "TGNavigationStack", package: "TGNavigationStack"),
                .product(name: "FactoryKit", package: "Factory"),
            ],
            path: "Tests/FluentWorkCoreTests"
        ),
    ]
)
