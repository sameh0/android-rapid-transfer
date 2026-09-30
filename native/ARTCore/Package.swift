// swift-tools-version: 6.0

import PackageDescription

// Platform-neutral core of Android Rapid Transfer: view models, the transfer
// engine and queue, settings and bug reports, plus the headless device probes.
// It links no UI framework and no Sparkle, so it builds on macOS and Linux;
// the macOS app (../AndroidRapidTransfer) depends on it by path.
let package = Package(
    name: "ARTCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AndroidRapidTransferCore", targets: ["AndroidRapidTransferCore"]),
        .executable(name: "ScanProbe", targets: ["ScanProbe"]),
        .executable(name: "RecursiveWalkProbe", targets: ["RecursiveWalkProbe"]),
        .executable(name: "SeedTestPhotos", targets: ["SeedTestPhotos"]),
        .executable(name: "LifecycleProbe", targets: ["LifecycleProbe"])
    ],
    dependencies: [
        .package(path: "../MTPKit"),
        // CryptoKit's API for the probes' SHA-256 on Linux (not linked on macOS).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
    ],
    targets: [
        .target(
            name: "AndroidRapidTransferCore",
            dependencies: [
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "SwiftMTP", package: "MTPKit"),
                .product(name: "USBWatcher", package: "MTPKit")
            ]
        ),
        .executableTarget(
            name: "ScanProbe",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(
            name: "RecursiveWalkProbe",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(
            name: "SeedTestPhotos",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit")
            ]
        ),
        // Drives the Core connection lifecycle (controller, hotplug, transfer
        // queue, quit path, bug report) headlessly against a real phone.
        .executableTarget(
            name: "LifecycleProbe",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "USBWatcher", package: "MTPKit"),
                .product(name: "SwiftMTP", package: "MTPKit"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(
            name: "AndroidRapidTransferCoreTests",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "SwiftMTP", package: "MTPKit"),
                .product(name: "USBWatcher", package: "MTPKit")
            ]
        )
    ]
)
