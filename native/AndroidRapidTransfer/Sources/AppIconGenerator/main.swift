import AndroidRapidTransferCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon from `AppIconArtwork`.
//
//   AppIconGenerator <AppIcon.icns>          every iconset size, packed by iconutil
//   AppIconGenerator --png <pixels> <file>   one PNG, for previews
//
// `Scripts/make-app-icon.sh` runs the first form to refresh Resources/AppIcon.icns.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func writePNG(pixels: Int, to url: URL) {
    guard let image = AppIconArtwork.image(pixels: pixels) else {
        fail("could not render the icon at \(pixels) px")
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fail("could not create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("could not write \(url.path)")
    }
}

func writeICNS(to output: URL) {
    let fileManager = FileManager.default
    let workspace = fileManager.temporaryDirectory
        .appending(path: "AppIconGenerator-\(UUID().uuidString)", directoryHint: .isDirectory)
    let iconset = workspace.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: workspace) }
    do {
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    } catch {
        fail("could not create \(iconset.path): \(error.localizedDescription)")
    }
    for image in AppIconArtwork.iconsetImages {
        writePNG(pixels: image.pixels, to: iconset.appending(path: image.fileName))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        fail("could not run iconutil: \(error.localizedDescription)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        fail("iconutil exited with status \(iconutil.terminationStatus)")
    }
    print("Wrote \(output.path)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.count {
case 1 where arguments[0].hasSuffix(".icns"):
    writeICNS(to: URL(fileURLWithPath: arguments[0]))
case 3 where arguments[0] == "--png":
    guard let pixels = Int(arguments[1]), pixels > 0 else { fail("pixels must be a positive integer") }
    writePNG(pixels: pixels, to: URL(fileURLWithPath: arguments[2]))
default:
    fail("usage: AppIconGenerator <AppIcon.icns> | --png <pixels> <file.png>")
}
