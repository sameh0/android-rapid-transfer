import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AndroidRapidTransferCore

final class AppIconArtworkTests: XCTestCase {
    /// Tests/AndroidRapidTransferCoreTests/<file> → the package root.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let committedIcon = packageRoot.appending(path: "Resources/AppIcon.icns")

    func testIconsetCoversEveryMacOSSize() {
        let expected: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        XCTAssertEqual(AppIconArtwork.iconsetImages.map(\.fileName), expected.map(\.0))
        XCTAssertEqual(AppIconArtwork.iconsetImages.map(\.pixels), expected.map(\.1))
    }

    func testRendersSquareImagesAtTheRequestedSize() throws {
        for pixels in [16, 32, 256, 1024] {
            let image = try XCTUnwrap(AppIconArtwork.image(pixels: pixels))
            XCTAssertEqual(image.width, pixels)
            XCTAssertEqual(image.height, pixels)
        }
        XCTAssertNil(AppIconArtwork.image(pixels: 0))
    }

    /// The Big Sur grid: a transparent margin around an opaque tile.
    func testTileSitsInsideTheIconGrid() throws {
        let pixels = try Pixels(XCTUnwrap(AppIconArtwork.image(pixels: 256)))
        XCTAssertEqual(pixels.alpha(x: 2, y: 2), 0, "The corner is outside the tile")
        XCTAssertEqual(pixels.alpha(x: 128, y: 4), 0, "The top margin is transparent")
        XCTAssertEqual(pixels.alpha(x: 128, y: 128), 255, "The centre is opaque")
        XCTAssertEqual(pixels.alpha(x: 40, y: 128), 255, "The tile starts at 100/1024 of the width")
        XCTAssertEqual(pixels.alpha(x: 4, y: 128), 0)
    }

    func testContinuousCornersStayInsideTheRect() {
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = AppIconArtwork.continuousRoundedRect(rect, radius: 185)
        XCTAssertEqual(path.boundingBoxOfPath.minX, rect.minX, accuracy: 0.5)
        XCTAssertEqual(path.boundingBoxOfPath.maxY, rect.maxY, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 4, y: rect.minY + 4)), "Corners are rounded")
        // A radius too big for the rect is clamped instead of overlapping.
        let small = AppIconArtwork.continuousRoundedRect(CGRect(x: 0, y: 0, width: 40, height: 20), radius: 100)
        XCTAssertEqual(small.boundingBoxOfPath.width, 40, accuracy: 0.5)
    }

    /// Resources/AppIcon.icns is generated from this artwork by
    /// Scripts/make-app-icon.sh; fails if the artwork changed without the
    /// icon being regenerated.
    func testCommittedIconMatchesTheArtwork() throws {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(Self.committedIcon as CFURL, nil),
            "Missing \(Self.committedIcon.path); run Scripts/make-app-icon.sh"
        )
        var sizes: Set<Int> = []
        var committed256: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            sizes.insert(image.width)
            if image.width == 256 { committed256 = image }
        }
        XCTAssertEqual(sizes, [16, 32, 64, 128, 256, 512, 1024])

        let committed = try Pixels(XCTUnwrap(committed256))
        let rendered = try Pixels(XCTUnwrap(AppIconArtwork.image(pixels: 256)))
        XCTAssertLessThan(
            committed.meanDifference(from: rendered),
            2,
            "Resources/AppIcon.icns is stale; run Scripts/make-app-icon.sh"
        )
    }
}

/// RGBA8 pixels of an image, redrawn into a known sRGB layout.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.featureUnsupported) }
        self.bytes = bytes
    }

    /// Alpha at (x, y), y measured from the top.
    func alpha(x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    func meanDifference(from other: Pixels) -> Double {
        guard width == other.width, height == other.height else { return .infinity }
        var total = 0
        for index in bytes.indices {
            total += abs(Int(bytes[index]) - Int(other.bytes[index]))
        }
        return Double(total) / Double(bytes.count)
    }
}
