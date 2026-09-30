#!/usr/bin/env python3
"""Draws the app icon as SVG for Linux and renders the hicolor PNG sizes.

The macOS icon is drawn in code with CoreGraphics
(native/ARTCore/Sources/AndroidRapidTransferCore/AppIconArtwork.swift), which
Linux does not have. This script is the same drawing, shape for shape and
colour for colour, written out as SVG: the 1024-point y-down design grid, the
continuous-corner tile, the display, the phone, the arrow and its speed lines.
Keep the two in step when the artwork changes.

Like AppIconArtwork, small renders drop fine detail (no speed lines below
64 px, no screen content below 128 px) and thicken bezels and the arrow, so
each PNG size is rendered from its own SVG variant; the scalable icon is the
full-detail one.

    Scripts/make-linux-icons.py            # writes packaging/icons/hicolor
    Scripts/make-linux-icons.py --check    # fails if the committed files differ

Needs rsvg-convert (librsvg) for the PNGs.
"""

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile

APP_ID = "com.sameh.AndroidRapidTransfer"
PNG_SIZES = [16, 22, 24, 32, 48, 64, 128, 256, 512]
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HICOLOR = os.path.join(PROJECT_DIR, "packaging", "icons", "hicolor")

CORNER_EXTENT = 1.52866483
CORNER_SEGMENTS = [
    ((-0.66993427, 0.06549600), (-1.08849323, 0), (-0.86840689, 0)),
    ((-0.06549569, 0.66993493), (-0.43028509, 0.15230465), (-0.15230552, 0.43028421)),
    ((0, CORNER_EXTENT), (0, 0.86840528), (0, 1.08849323)),
]


def num(value):
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text == "-0" else text


def rgba(r, g, b, a=1.0):
    return f"#{round(r * 255):02x}{round(g * 255):02x}{round(b * 255):02x}", a


def squircle(x, y, w, h, radius):
    """AppIconArtwork.continuousRoundedRect as SVG path data."""
    radius = min(radius, min(w, h) / 2 / CORNER_EXTENT)
    corners = [
        ((x + w, y), lambda p: p),
        ((x + w, y + h), lambda p: (-p[1], p[0])),
        ((x, y + h), lambda p: (-p[0], -p[1])),
        ((x, y), lambda p: (p[1], -p[0])),
    ]
    parts = []
    for index, (origin, rotate) in enumerate(corners):
        def point(local):
            mx, my = rotate(local)
            return f"{num(origin[0] + mx * radius)} {num(origin[1] + my * radius)}"

        parts.append(("M" if index == 0 else "L") + point((-CORNER_EXTENT, 0)))
        for to, c1, c2 in CORNER_SEGMENTS:
            parts.append(f"C{point(c1)} {point(c2)} {point(to)}")
    return "".join(parts) + "Z"


class Svg:
    def __init__(self):
        self.defs = []
        self.body = []
        self.ids = 0

    def new_id(self, prefix):
        self.ids += 1
        return f"{prefix}{self.ids}"

    def linear(self, stops, x1, y1, x2, y2):
        gid = self.new_id("g")
        rows = "".join(
            f'<stop offset="{num(offset)}" stop-color="{c}"'
            + (f' stop-opacity="{num(a)}"' if a != 1 else "") + "/>"
            for offset, (c, a) in stops
        )
        self.defs.append(
            f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{num(x1)}" y1="{num(y1)}"'
            f' x2="{num(x2)}" y2="{num(y2)}">{rows}</linearGradient>'
        )
        return f"url(#{gid})"

    def radial(self, stops, cx, cy, r):
        gid = self.new_id("g")
        rows = "".join(
            f'<stop offset="{num(offset)}" stop-color="{c}" stop-opacity="{num(a)}"/>'
            for offset, (c, a) in stops
        )
        self.defs.append(
            f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{num(cx)}" cy="{num(cy)}"'
            f' r="{num(r)}">{rows}</radialGradient>'
        )
        return f"url(#{gid})"

    def shadow(self, dy, blur, color):
        """A CoreGraphics shadow (offset down by dy, blur radius) as a filter."""
        fid = self.new_id("s")
        c, a = color
        self.defs.append(
            f'<filter id="{fid}" x="-25%" y="-25%" width="150%" height="150%" color-interpolation-filters="sRGB">'
            f'<feDropShadow dx="0" dy="{num(dy)}" stdDeviation="{num(blur / 2)}"'
            f' flood-color="{c}" flood-opacity="{num(a)}"/></filter>'
        )
        return f"url(#{fid})"

    def clip(self, path):
        cid = self.new_id("c")
        self.defs.append(f'<clipPath id="{cid}"><path d="{path}"/></clipPath>')
        return f"url(#{cid})"

    def document(self, title):
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f"<title>{title}</title>\n"
            "<defs>\n" + "\n".join(self.defs) + "\n</defs>\n"
            + "\n".join(self.body) + "\n</svg>\n"
        )


def fill(path, paint, opacity=1.0, extra=""):
    op = f' fill-opacity="{num(opacity)}"' if opacity != 1 else ""
    return f'<path d="{path}" fill="{paint}"{op}{extra}/>'


def device_shadow(svg, strength=1.0):
    return svg.shadow(10 * strength, 26 * strength, rgba(0.02, 0.08, 0.25, 0.38))


def draw(pixels):
    show_speed_lines = pixels >= 64
    show_screen_content = pixels >= 128
    weight = 1.6 if pixels < 64 else 1.0
    svg = Svg()
    out = svg.body

    # Body: the tile, its drop shadow, gradient, lighting and rim.
    body = squircle(100, 100, 824, 824, 185)
    c, _ = rgba(0.10, 0.45, 0.62)
    out.append(fill(body, c, extra=f' filter="{svg.shadow(12, 28, rgba(0, 0, 0, 0.32))}"'))
    body_clip = svg.clip(body)
    out.append(f'<g clip-path="{body_clip}">')
    out.append(fill(body, svg.linear(
        [(0, rgba(0.18, 0.84, 0.52)), (0.32, rgba(0.05, 0.70, 0.66)),
         (0.72, rgba(0.13, 0.46, 0.96)), (1, rgba(0.29, 0.30, 0.93))],
        100, 100, 924, 924)))
    out.append(fill(body, svg.radial([(0, rgba(1, 1, 1, 0.24)), (1, rgba(1, 1, 1, 0))], 400, 60, 700)))
    out.append(fill(body, svg.linear(
        [(0.55, rgba(0, 0, 0, 0)), (1, rgba(0.02, 0.05, 0.25, 0.28))], 0, 100, 0, 924)))
    out.append("</g>")
    rim = svg.linear([(0, rgba(1, 1, 1, 0.45)), (0.5, rgba(1, 1, 1, 0))], 0, 100, 0, 924)
    out.append(f'<path d="{squircle(102, 102, 820, 820, 183)}" fill="none" stroke="{rim}" stroke-width="4"/>')

    # Display: stand, bezel, screen with photo tiles, glass sheen.
    fx, fy, fw, fh = 372, 262, 468, 330
    mid_x, max_y = fx + fw / 2, fy + fh
    neck = (f"M{num(mid_x - 52)} {num(max_y - 4)}L{num(mid_x + 52)} {num(max_y - 4)}"
            f"L{num(mid_x + 70)} {num(max_y + 78)}L{num(mid_x - 70)} {num(max_y + 78)}Z")
    foot = squircle(mid_x - 118, max_y + 70, 236, 26, 12)
    out.append(fill(neck + foot, rgba(0.84, 0.88, 0.94)[0], extra=f' filter="{device_shadow(svg)}"'))
    out.append(fill(squircle(fx, fy, fw, fh, 38), rgba(0.97, 0.98, 1)[0], extra=f' filter="{device_shadow(svg)}"'))
    inset = 22 * weight
    screen = squircle(fx + inset, fy + inset, fw - 2 * inset, fh - 2 * inset, 20)
    out.append(f'<g clip-path="{svg.clip(screen)}">')
    out.append(fill(screen, svg.linear(
        [(0, rgba(0.10, 0.17, 0.38)), (1, rgba(0.16, 0.30, 0.66))], fx, fy, fx + fw, fy + fh)))
    if show_screen_content:
        tile, gap = 84, 18
        ox, oy = fx + fw - 44 - 2 * tile - gap, fy + fh / 2 - tile - gap / 2
        tints = [rgba(0.35, 0.86, 0.62, 0.95), rgba(0.99, 0.78, 0.30, 0.95),
                 rgba(0.60, 0.55, 1.00, 0.95), rgba(0.35, 0.86, 0.86, 0.95)]
        for row in range(2):
            for column in range(2):
                c, a = tints[row * 2 + column]
                out.append(fill(squircle(ox + column * (tile + gap), oy + row * (tile + gap), tile, tile, 14), c, a))
    out.append(fill(screen, svg.linear([(0, rgba(1, 1, 1, 0.14)), (0.6, rgba(1, 1, 1, 0))], 0, fy, 0, max_y)))
    out.append("</g>")

    # Phone: shell, screen, camera and a column of photo rows.
    px, py, pw, ph = 196, 372, 236, 452
    out.append(fill(squircle(px, py, pw, ph, 50), rgba(0.97, 0.98, 1)[0],
                    extra=f' filter="{device_shadow(svg, 1.3)}"'))
    inset = 18 * weight
    sx, sy, sw, sh = px + inset, py + inset, pw - 2 * inset, ph - 2 * inset
    phone_screen = squircle(sx, sy, sw, sh, 36)
    out.append(f'<g clip-path="{svg.clip(phone_screen)}">')
    out.append(fill(phone_screen, svg.linear(
        [(0, rgba(0.09, 0.30, 0.30)), (1, rgba(0.10, 0.20, 0.42))], px, py, px + pw, py + ph)))
    if show_screen_content:
        out.append(f'<circle cx="{num(sx + sw / 2)}" cy="{num(sy + 27)}" r="9" fill="#000000" fill-opacity="0.55"/>')
        tints = [rgba(0.35, 0.86, 0.62, 0.9), rgba(0.99, 0.78, 0.30, 0.9),
                 rgba(0.47, 0.66, 1.00, 0.9), rgba(0.99, 0.53, 0.42, 0.9)]
        for index, (c, a) in enumerate(tints):
            y = sy + 64 + index * 84
            out.append(fill(squircle(sx + 22, y, 60, 60, 12), c, a))
            out.append(fill(squircle(sx + 98, y + 14, 82, 12, 6), "#ffffff", 0.45))
            out.append(fill(squircle(sx + 98, y + 36, 52, 10, 5), "#ffffff", 0.22))
    out.append("</g>")

    # Arrow: a quadratic shaft and a notched head, sharing one shadow.
    start, control, end = (316, 548), (400, 318), (548, 360)
    angle = math.atan2(end[1] - control[1], end[0] - control[0])
    d = (math.cos(angle), math.sin(angle))
    n = (-d[1], d[0])
    head_length, head_width = 176, 212
    tip = (end[0] + d[0] * head_length * 0.7, end[1] + d[1] * head_length * 0.7)
    back = (tip[0] - d[0] * head_length, tip[1] - d[1] * head_length)
    left = (back[0] + n[0] * head_width / 2, back[1] + n[1] * head_width / 2)
    right = (back[0] - n[0] * head_width / 2, back[1] - n[1] * head_width / 2)
    notch = (back[0] + d[0] * 44, back[1] + d[1] * 44)
    head = (f"M{num(tip[0])} {num(tip[1])}L{num(left[0])} {num(left[1])}"
            f"Q{num(notch[0])} {num(notch[1])} {num(right[0])} {num(right[1])}Z")
    shaft = f"M{start[0]} {start[1]}Q{control[0]} {control[1]} {end[0]} {end[1]}"

    if show_speed_lines:
        for (x1, y1), (x2, y2), width, alpha in [
            ((132, 520), (176, 496), 20, 0.9),
            ((120, 590), (176, 560), 24, 0.95),
            ((138, 656), (176, 636), 16, 0.8),
        ]:
            out.append(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="#ffffff" stroke-opacity="{num(alpha)}"'
                       f' stroke-width="{width}" stroke-linecap="round"/>')

    paint = svg.linear([(0, rgba(1, 0.88, 0.32)), (1, rgba(1, 0.55, 0.16))],
                       tip[0], control[1] - 40, start[0] - 40, start[1] + 40)
    out.append(f'<g filter="{svg.shadow(8, 20, rgba(0.30, 0.08, 0, 0.45))}">')
    out.append(f'<path d="{shaft}" fill="none" stroke="{paint}" stroke-width="{num(76 * weight)}"'
               ' stroke-linecap="round" stroke-linejoin="round"/>')
    out.append(fill(head, paint))
    out.append("</g>")
    return svg.document("Android Rapid Transfer")


def render(svg_text, pixels, destination, workdir):
    source = os.path.join(workdir, f"icon-{pixels}.svg")
    with open(source, "w", encoding="utf-8") as handle:
        handle.write(svg_text)
    subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels), "-o", destination, source], check=True)


def generate(root, workdir):
    scalable = os.path.join(root, "scalable", "apps")
    os.makedirs(scalable, exist_ok=True)
    with open(os.path.join(scalable, f"{APP_ID}.svg"), "w", encoding="utf-8") as handle:
        handle.write(draw(1024))
    for pixels in PNG_SIZES:
        folder = os.path.join(root, f"{pixels}x{pixels}", "apps")
        os.makedirs(folder, exist_ok=True)
        render(draw(pixels), pixels, os.path.join(folder, f"{APP_ID}.png"), workdir)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="fail if the committed icons are out of date")
    parser.add_argument("--output", default=HICOLOR, help="hicolor directory to write (default: packaging/icons/hicolor)")
    args = parser.parse_args()
    if shutil.which("rsvg-convert") is None:
        sys.exit("ERROR: rsvg-convert (librsvg) is required")
    with tempfile.TemporaryDirectory() as workdir:
        if not args.check:
            generate(args.output, workdir)
            print(f"Wrote {args.output}")
            return
        fresh = os.path.join(workdir, "hicolor")
        generate(fresh, workdir)
        # The SVG is compared exactly; PNGs only by existence and size, since
        # rsvg-convert output varies slightly between librsvg versions.
        stale = []
        svg = os.path.join("scalable", "apps", f"{APP_ID}.svg")
        with open(os.path.join(fresh, svg), "rb") as a:
            expected = a.read()
        try:
            with open(os.path.join(args.output, svg), "rb") as b:
                if b.read() != expected:
                    stale.append(svg)
        except FileNotFoundError:
            stale.append(svg)
        for pixels in PNG_SIZES:
            png = os.path.join(args.output, f"{pixels}x{pixels}", "apps", f"{APP_ID}.png")
            if not os.path.isfile(png):
                stale.append(os.path.relpath(png, args.output))
        if stale:
            sys.exit("ERROR: out-of-date icons (run Scripts/make-linux-icons.py): " + ", ".join(stale))
        print("Icons: up to date.")


if __name__ == "__main__":
    main()
