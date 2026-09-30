// swift-tools-version:6.0
import PackageDescription

// The Linux desktop UI layer: a thin Swift layer over GTK 4 + libadwaita (C API).
// Linux only; there is nothing to build on macOS.
let package = Package(
    name: "AndroidRapidTransferLinux",
    products: [
        .library(name: "ARTGtk", targets: ["ARTGtk"]),
        .executable(name: "art-gtk-demo", targets: ["art-gtk-demo"]),
    ],
    targets: [
        // GTK 4 and libadwaita via pkg-config. SwiftPM has no pacman provider:
        // on Arch install `gtk4 libadwaita` (headers ship in the main packages).
        .systemLibrary(
            name: "CGtk",
            path: "Sources/CGtk",
            pkgConfig: "gtk4 libadwaita-1",
            providers: [
                .apt(["libgtk-4-dev", "libadwaita-1-dev"]),
                .yum(["gtk4-devel", "libadwaita-devel"]),
            ]
        ),
        .target(name: "ARTGtk", dependencies: ["CGtk"]),
        .executableTarget(name: "art-gtk-demo", dependencies: ["ARTGtk"]),
        .testTarget(name: "ARTGtkTests", dependencies: ["ARTGtk"]),
    ]
)
