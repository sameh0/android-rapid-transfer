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
        // The platform-neutral core (view models, transfer engine, probes).
        .package(path: "../ARTCore"),
        .package(path: "../MTPKit"),
        // Auto-updates. Pinned exactly: the packaging scripts embed this
        // framework and its signing layout is version-specific.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Renders Resources/AppIcon.icns from AppIconArtwork; see
        // Scripts/make-app-icon.sh.
        .executableTarget(
            name: "AppIconGenerator",
            dependencies: [.product(name: "AndroidRapidTransferCore", package: "ARTCore")]
        ),
        .executableTarget(
            name: "AndroidRapidTransfer",
            dependencies: [
                .product(name: "AndroidRapidTransferCore", package: "ARTCore"),
                .product(name: "MTPKit", package: "MTPKit"),
                .product(name: "USBWatcher", package: "MTPKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "AndroidRapidTransferTests",
            dependencies: ["AndroidRapidTransfer"]
        )
    ]
)
