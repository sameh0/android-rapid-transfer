// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AndroidRapidTransfer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AndroidRapidTransfer", targets: ["AndroidRapidTransfer"])
    ],
    dependencies: [
        .package(path: "../MTPKit"),
        // Auto-updates. Pinned exactly: the packaging scripts embed this
        // framework and its signing layout is version-specific.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
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
                .product(name: "MTPKit", package: "MTPKit")
            ]
        ),
        .executableTarget(
            name: "RecursiveWalkProbe",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit")
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
                .product(name: "SwiftMTP", package: "MTPKit")
            ]
        ),
        // Renders Resources/AppIcon.icns from AppIconArtwork; see
        // Scripts/make-app-icon.sh.
        .executableTarget(
            name: "AppIconGenerator",
            dependencies: ["AndroidRapidTransferCore"]
        ),
        .executableTarget(
            name: "AndroidRapidTransfer",
            dependencies: [
                "AndroidRapidTransferCore",
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "USBWatcher", package: "MTPKit"),
                .product(name: "Sparkle", package: "Sparkle")
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
        ),
        .testTarget(
            name: "AndroidRapidTransferTests",
            dependencies: ["AndroidRapidTransfer"]
        )
    ]
)
