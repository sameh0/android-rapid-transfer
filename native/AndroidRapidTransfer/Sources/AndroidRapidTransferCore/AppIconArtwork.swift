import CoreGraphics
import Foundation

/// The app icon, drawn in code so every size is reproducible from one source.
///
/// `AppIconGenerator` renders it into `Resources/AppIcon.icns` for the
/// packaging scripts, and an unbundled `swift run` draws it at launch for the
/// Dock and the About panel. It follows the macOS icon grid: a 1024-point
/// canvas with an 824-point continuous-corner body, a soft drop shadow, and a
/// lit top edge. The motif is original — a phone sending a swift arrow to a
/// desktop display over a green-to-blue gradient — and uses no third-party
/// marks.
public enum AppIconArtwork {
    /// The sizes, in pixels, an `.iconset` needs, keyed by file name.
    public static let iconsetImages: [(fileName: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { points in
        [
            (fileName: "icon_\(points)x\(points).png", pixels: points),
            (fileName: "icon_\(points)x\(points)@2x.png", pixels: points * 2)
        ]
    }

    /// Renders the icon as a square, sRGB, premultiplied-alpha image.
    public static func image(pixels: Int) -> CGImage? {
        guard pixels > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        draw(in: context, pixels: CGFloat(pixels))
        return context.makeImage()
    }

    /// Draws the icon into `context`, which spans `pixels` square in its
    /// base coordinates.
    public static func draw(in context: CGContext, pixels: CGFloat) {
        let scale = pixels / canvas
        // Work in a 1024-point, y-down space like the design grid. Shadow
        // offsets are in device space, so they are scaled by hand.
        context.saveGState()
        context.translateBy(x: 0, y: pixels)
        context.scaleBy(x: scale, y: -scale)
        let detail = Detail(pixels: pixels)
        drawBody(in: context, scale: scale)
        drawDisplay(in: context, scale: scale, detail: detail)
        drawPhone(in: context, scale: scale, detail: detail)
        drawArrow(in: context, scale: scale, detail: detail)
        context.restoreGState()
    }

    // MARK: - Grid

    private static let canvas: CGFloat = 1024
    private static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    private static let bodyRadius: CGFloat = 185

    /// Small renders drop the fine detail that turns into mush below ~64 px,
    /// and thicken bezels and the arrow so the shapes still read.
    private struct Detail {
        let showsSpeedLines: Bool
        let showsScreenContent: Bool
        /// Multiplies bezel widths and the arrow's shaft.
        let weight: CGFloat

        init(pixels: CGFloat) {
            showsSpeedLines = pixels >= 64
            showsScreenContent = pixels >= 128
            weight = pixels < 64 ? 1.6 : 1
        }
    }

    // MARK: - Layers

    private static func drawBody(in context: CGContext, scale: CGFloat) {
        let shape = continuousRoundedRect(body, radius: bodyRadius)

        // Drop shadow under the tile, as on every Big Sur-style icon.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -12 * scale),
            blur: 28 * scale,
            color: color(0, 0, 0, 0.32)
        )
        context.addPath(shape)
        context.setFillColor(color(0.10, 0.45, 0.62))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        // Fresh green (the phone side) into electric blue (the Mac side).
        fillLinear(
            in: context,
            colors: [
                color(0.18, 0.84, 0.52),
                color(0.05, 0.70, 0.66),
                color(0.13, 0.46, 0.96),
                color(0.29, 0.30, 0.93)
            ],
            locations: [0, 0.32, 0.72, 1],
            from: CGPoint(x: body.minX, y: body.minY),
            to: CGPoint(x: body.maxX, y: body.maxY)
        )
        // Light from above, shade below: gives the flat tile some depth.
        fillRadial(
            in: context,
            colors: [color(1, 1, 1, 0.24), color(1, 1, 1, 0)],
            center: CGPoint(x: 400, y: 60),
            radius: 700
        )
        fillLinear(
            in: context,
            colors: [color(0, 0, 0, 0), color(0.02, 0.05, 0.25, 0.28)],
            locations: [0.55, 1],
            from: CGPoint(x: 0, y: body.minY),
            to: CGPoint(x: 0, y: body.maxY)
        )
        context.restoreGState()

        // A hairline rim catches the light along the top edge.
        context.saveGState()
        context.addPath(continuousRoundedRect(body.insetBy(dx: 2, dy: 2), radius: bodyRadius - 2))
        context.setLineWidth(4)
        context.replacePathWithStrokedPath()
        context.clip()
        fillLinear(
            in: context,
            colors: [color(1, 1, 1, 0.45), color(1, 1, 1, 0)],
            locations: [0, 0.5],
            from: CGPoint(x: 0, y: body.minY),
            to: CGPoint(x: 0, y: body.maxY)
        )
        context.restoreGState()
    }

    private static let displayFrame = CGRect(x: 372, y: 262, width: 468, height: 330)
    private static let phoneFrame = CGRect(x: 196, y: 372, width: 236, height: 452)

    private static func drawDisplay(in context: CGContext, scale: CGFloat, detail: Detail) {
        let frame = displayFrame
        // Stand: a tapered neck and a flat foot.
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: frame.midX - 52, y: frame.maxY - 4))
        neck.addLine(to: CGPoint(x: frame.midX + 52, y: frame.maxY - 4))
        neck.addLine(to: CGPoint(x: frame.midX + 70, y: frame.maxY + 78))
        neck.addLine(to: CGPoint(x: frame.midX - 70, y: frame.maxY + 78))
        neck.closeSubpath()
        let foot = continuousRoundedRect(
            CGRect(x: frame.midX - 118, y: frame.maxY + 70, width: 236, height: 26),
            radius: 12
        )
        withDeviceShadow(context, scale: scale) {
            context.addPath(neck)
            context.addPath(foot)
            context.setFillColor(color(0.84, 0.88, 0.94))
            context.fillPath()
        }

        let bezel = continuousRoundedRect(frame, radius: 38)
        withDeviceShadow(context, scale: scale) {
            context.addPath(bezel)
            context.setFillColor(color(0.97, 0.98, 1))
            context.fillPath()
        }

        let screen = continuousRoundedRect(frame.insetBy(dx: 22 * detail.weight, dy: 22 * detail.weight), radius: 20)
        context.saveGState()
        context.addPath(screen)
        context.clip()
        fillLinear(
            in: context,
            colors: [color(0.10, 0.17, 0.38), color(0.16, 0.30, 0.66)],
            locations: [0, 1],
            from: CGPoint(x: frame.minX, y: frame.minY),
            to: CGPoint(x: frame.maxX, y: frame.maxY)
        )
        if detail.showsScreenContent {
            // A grid of photo tiles: the files that just arrived.
            let tile: CGFloat = 84
            let gap: CGFloat = 18
            let origin = CGPoint(x: frame.maxX - 44 - 2 * tile - gap, y: frame.midY - tile - gap / 2)
            let tints = [
                color(0.35, 0.86, 0.62, 0.95), color(0.99, 0.78, 0.30, 0.95),
                color(0.60, 0.55, 1.00, 0.95), color(0.35, 0.86, 0.86, 0.95)
            ]
            for row in 0..<2 {
                for column in 0..<2 {
                    let rect = CGRect(
                        x: origin.x + CGFloat(column) * (tile + gap),
                        y: origin.y + CGFloat(row) * (tile + gap),
                        width: tile,
                        height: tile
                    )
                    context.addPath(continuousRoundedRect(rect, radius: 14))
                    context.setFillColor(tints[row * 2 + column])
                    context.fillPath()
                }
            }
        }
        // Glass sheen across the top of the screen.
        fillLinear(
            in: context,
            colors: [color(1, 1, 1, 0.14), color(1, 1, 1, 0)],
            locations: [0, 0.6],
            from: CGPoint(x: 0, y: frame.minY),
            to: CGPoint(x: 0, y: frame.maxY)
        )
        context.restoreGState()
    }

    private static func drawPhone(in context: CGContext, scale: CGFloat, detail: Detail) {
        let frame = phoneFrame
        let shell = continuousRoundedRect(frame, radius: 50)
        withDeviceShadow(context, scale: scale, strength: 1.3) {
            context.addPath(shell)
            context.setFillColor(color(0.97, 0.98, 1))
            context.fillPath()
        }

        let screenRect = frame.insetBy(dx: 18 * detail.weight, dy: 18 * detail.weight)
        let screen = continuousRoundedRect(screenRect, radius: 36)
        context.saveGState()
        context.addPath(screen)
        context.clip()
        fillLinear(
            in: context,
            colors: [color(0.09, 0.30, 0.30), color(0.10, 0.20, 0.42)],
            locations: [0, 1],
            from: CGPoint(x: frame.minX, y: frame.minY),
            to: CGPoint(x: frame.maxX, y: frame.maxY)
        )
        if detail.showsScreenContent {
            // Punch-hole camera, then a column of photo rows.
            context.addEllipse(in: CGRect(x: screenRect.midX - 9, y: screenRect.minY + 18, width: 18, height: 18))
            context.setFillColor(color(0, 0, 0, 0.55))
            context.fillPath()
            let tints = [
                color(0.35, 0.86, 0.62, 0.9), color(0.99, 0.78, 0.30, 0.9),
                color(0.47, 0.66, 1.00, 0.9), color(0.99, 0.53, 0.42, 0.9)
            ]
            for (index, tint) in tints.enumerated() {
                let y = screenRect.minY + 64 + CGFloat(index) * 84
                let thumb = CGRect(x: screenRect.minX + 22, y: y, width: 60, height: 60)
                context.addPath(continuousRoundedRect(thumb, radius: 12))
                context.setFillColor(tint)
                context.fillPath()
                let line = CGRect(x: thumb.maxX + 16, y: y + 14, width: 82, height: 12)
                context.addPath(continuousRoundedRect(line, radius: 6))
                context.setFillColor(color(1, 1, 1, 0.45))
                context.fillPath()
                let shortLine = CGRect(x: thumb.maxX + 16, y: y + 36, width: 52, height: 10)
                context.addPath(continuousRoundedRect(shortLine, radius: 5))
                context.setFillColor(color(1, 1, 1, 0.22))
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    /// A bold, warm arrow arcing from the phone into the display, with speed
    /// lines trailing it: the "rapid" in the name.
    private static func drawArrow(in context: CGContext, scale: CGFloat, detail: Detail) {
        let start = CGPoint(x: 316, y: 548)
        let control = CGPoint(x: 400, y: 318)
        let end = CGPoint(x: 548, y: 360)

        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addQuadCurve(to: end, control: control)
        let stroked = shaft.copy(strokingWithWidth: 76 * detail.weight, lineCap: .round, lineJoin: .round, miterLimit: 10)

        // The head points along the curve's tangent at its end, its notched
        // back overlapping the shaft.
        let angle = atan2(end.y - control.y, end.x - control.x)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let headLength: CGFloat = 176
        let headWidth: CGFloat = 212
        let tip = CGPoint(x: end.x + direction.x * headLength * 0.7, y: end.y + direction.y * headLength * 0.7)
        let back = CGPoint(x: tip.x - direction.x * headLength, y: tip.y - direction.y * headLength)
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x + normal.x * headWidth / 2, y: back.y + normal.y * headWidth / 2))
        head.addQuadCurve(
            to: CGPoint(x: back.x - normal.x * headWidth / 2, y: back.y - normal.y * headWidth / 2),
            control: CGPoint(x: back.x + direction.x * 44, y: back.y + direction.y * 44)
        )
        head.closeSubpath()

        if detail.showsSpeedLines {
            context.saveGState()
            context.setLineCap(.round)
            let lines: [(from: CGPoint, to: CGPoint, width: CGFloat, alpha: CGFloat)] = [
                (CGPoint(x: 132, y: 520), CGPoint(x: 176, y: 496), 20, 0.9),
                (CGPoint(x: 120, y: 590), CGPoint(x: 176, y: 560), 24, 0.95),
                (CGPoint(x: 138, y: 656), CGPoint(x: 176, y: 636), 16, 0.8)
            ]
            for line in lines {
                context.setStrokeColor(color(1, 1, 1, line.alpha))
                context.setLineWidth(line.width)
                context.move(to: line.from)
                context.addLine(to: line.to)
                context.strokePath()
            }
            context.restoreGState()
        }

        // Shaft and head are filled separately inside one transparency layer,
        // so they share a single shadow and no winding rule can punch a hole
        // where they overlap.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -8 * scale),
            blur: 20 * scale,
            color: color(0.30, 0.08, 0, 0.45)
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for part in [stroked, head] {
            context.saveGState()
            context.addPath(part)
            context.clip()
            fillLinear(
                in: context,
                colors: [color(1, 0.88, 0.32), color(1, 0.55, 0.16)],
                locations: [0, 1],
                from: CGPoint(x: tip.x, y: control.y - 40),
                to: CGPoint(x: start.x - 40, y: start.y + 40)
            )
            context.restoreGState()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Helpers

    private static func withDeviceShadow(
        _ context: CGContext,
        scale: CGFloat,
        strength: CGFloat = 1,
        _ draw: () -> Void
    ) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10 * scale * strength),
            blur: 26 * scale * strength,
            color: color(0.02, 0.08, 0.25, 0.38)
        )
        draw()
        context.restoreGState()
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func fillLinear(
        in context: CGContext,
        colors: [CGColor],
        locations: [CGFloat],
        from start: CGPoint,
        to end: CGPoint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func fillRadial(in context: CGContext, colors: [CGColor], center: CGPoint, radius: CGFloat) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
    }

    /// A rounded rectangle with continuous ("squircle") corners, the shape
    /// macOS uses for icon tiles. Each corner blends into its edges over
    /// about 1.53 × `radius`, instead of the abrupt start of a circular arc.
    static func continuousRoundedRect(_ rect: CGRect, radius requested: CGFloat) -> CGPath {
        let radius = min(requested, min(rect.width, rect.height) / 2 / cornerExtent)
        // The top-right corner in local coordinates: the corner point is the
        // origin, the path arrives along the top edge (x < 0, y = 0) and
        // leaves down the right edge (x = 0, y > 0), y pointing down.
        let segments: [(to: CGPoint, control1: CGPoint, control2: CGPoint)] = [
            (CGPoint(x: -0.66993427, y: 0.06549600), CGPoint(x: -1.08849323, y: 0), CGPoint(x: -0.86840689, y: 0)),
            (CGPoint(x: -0.06549569, y: 0.66993493), CGPoint(x: -0.43028509, y: 0.15230465), CGPoint(x: -0.15230552, y: 0.43028421)),
            (CGPoint(x: 0, y: cornerExtent), CGPoint(x: 0, y: 0.86840528), CGPoint(x: 0, y: 1.08849323))
        ]
        // Each corner is the previous one turned a quarter clockwise.
        let corners: [(origin: CGPoint, map: (CGPoint) -> CGPoint)] = [
            (CGPoint(x: rect.maxX, y: rect.minY), { $0 }),
            (CGPoint(x: rect.maxX, y: rect.maxY), { CGPoint(x: -$0.y, y: $0.x) }),
            (CGPoint(x: rect.minX, y: rect.maxY), { CGPoint(x: -$0.x, y: -$0.y) }),
            (CGPoint(x: rect.minX, y: rect.minY), { CGPoint(x: $0.y, y: -$0.x) })
        ]
        let path = CGMutablePath()
        for (index, corner) in corners.enumerated() {
            func point(_ local: CGPoint) -> CGPoint {
                let mapped = corner.map(local)
                return CGPoint(x: corner.origin.x + mapped.x * radius, y: corner.origin.y + mapped.y * radius)
            }
            let start = point(CGPoint(x: -cornerExtent, y: 0))
            if index == 0 {
                path.move(to: start)
            } else {
                path.addLine(to: start)
            }
            for segment in segments {
                path.addCurve(to: point(segment.to), control1: point(segment.control1), control2: point(segment.control2))
            }
        }
        path.closeSubpath()
        return path
    }

    private static let cornerExtent: CGFloat = 1.52866483
}
