// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MTPKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "USBWatcher", targets: ["USBWatcher"]),
        .executable(name: "usb-watch", targets: ["usb-watch"]),
        .library(name: "SwiftMTP", targets: ["SwiftMTP"]),
        .executable(name: "mtp-probe", targets: ["mtp-probe"]),
        .executable(name: "swift-provider-probe", targets: ["swift-provider-probe"])
    ],
    dependencies: [
        // CryptoKit's API for the probes' SHA-256 on Linux (not linked on macOS).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
    ],
    targets: [
        .target(name: "MTPKit"),
        .target(
            name: "USBWatcher",
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),
        .executableTarget(name: "usb-watch", dependencies: ["USBWatcher"]),
        // Pure-Swift PTP/MTP stack over IOUSBHost. SwiftMTPProvider implements
        // MTPKit's MTPDeviceProvider on top of it.
        .target(
            name: "SwiftMTP",
            dependencies: ["MTPKit"],
            linkerSettings: [
                .linkedFramework("IOUSBHost", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(name: "mtp-probe", dependencies: ["SwiftMTP", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))]),
        // End-to-end device probe over the public MTPDeviceProvider API only.
        .executableTarget(name: "swift-provider-probe", dependencies: ["SwiftMTP", "MTPKit", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "USBWatcherTests", dependencies: ["USBWatcher"]),
        .testTarget(name: "SwiftMTPTests", dependencies: ["SwiftMTP", "MTPKit"])
    ]
)
