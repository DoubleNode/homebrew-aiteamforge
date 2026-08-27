#!/usr/bin/env python3

#
#  lcars-cockpit-icon.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""XACA-0161-005 — generator for the iPad PWA cockpit home-screen icons.

The PNGs next to this file are BUILD OUTPUT, not hand-authored art. This
script is the source. Regenerate with:

    python3 lcars-ui/cockpit/icons/lcars-cockpit-icon.py

WHY A GENERATOR AND NOT CHECKED-IN ART
======================================
iOS asks for the same mark at five different pixel sizes and Android's
maskable spec asks for a sixth composition with a different safe area. Six
hand-exported PNGs drift the moment anyone touches one of them, and a
mismatch is invisible until it is on a home screen. One parametric source
makes every size provably the same mark.

DESIGN
======
LCARS elbow chrome (Okuda) plus a terminal prompt glyph, because that is
literally what the route is: an LCARS frame around tmux panes. Palette is
taken verbatim from `lcars-ui/css/lcars.css` `:root` — purple is the Academy
org colour, orange/peach are the warm accents, cyan is the DoubleNode blue
spectrum.

Rendered at 4x and downsampled with LANCZOS; PIL has no antialiased shape
rasteriser, so supersampling is the only way to get clean elbow curves.

TWO COMPOSITIONS, AND WHY
=========================
`any`      — full-bleed, opaque, square, mark at full scale. iOS applies its
             own squircle mask to `apple-touch-icon` and clips ~10% off each
             edge; nothing load-bearing sits in that margin.
`maskable` — the same mark scaled to 78% and centred, so the whole of it
             survives Android's worst-case circular mask (the spec's safe
             zone is a centred circle of 80% diameter).

Every output is RGB (no alpha). Transparent home-screen icons render black-
on-black on some iOS versions and there is no reason to risk it.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - operator-facing message, not a code path
    sys.exit("Pillow is required: python3 -m pip install Pillow")

# --- palette, copied from lcars-ui/css/lcars.css :root ----------------------
BLACK = (0x00, 0x00, 0x00)
PURPLE = (0xCC, 0x99, 0xFF)   # --lcars-purple  / --org-academy
ORANGE = (0xFF, 0x99, 0x00)   # --lcars-orange
PEACH = (0xFF, 0xCC, 0x99)    # --lcars-peach   / --div-academy
CYAN = (0x99, 0xCC, 0xFF)     # --lcars-cyan

SS = 4  # supersample factor

# Sizes iOS actually requests for `apple-touch-icon`, plus the two web-app
# manifest sizes. 167 is iPad Pro, 152 is iPad, 180 is the modern default,
# 120 is iPhone @2x — all four were observed as live requests during the
# 2026-08-26 device spike or are the documented set alongside them.
APPLE_SIZES = (120, 152, 167, 180)
MANIFEST_SIZES = (192, 512)
MASKABLE_SIZES = (512,)


def _rr(draw: "ImageDraw.ImageDraw", box, radius, fill) -> None:
    """Rounded rect in fractional (0..1) coordinates."""
    x0, y0, x1, y1 = box
    draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill)


def _fillet(draw: "ImageDraw.ImageDraw", cx: float, cy: float,
            radius: float, fill, sign_y: float) -> None:
    """Round the CONCAVE corner where two bars of an LCARS elbow meet.

    A concave corner is rounded by ADDING material, not removing it: the
    wedge between the sharp corner and an arc that bulges away from it gets
    filled. So this draws the corner square in the bar colour and then punches
    a background disc, centred `radius` away along both axes, out of it.

    `cx`/`cy` are the sharp corner in pixels, `sign_y` is +1 when the empty
    quadrant is below the corner (top elbow) and -1 when it is above (bottom
    elbow). Getting this backwards silently produces a square corner, which is
    why the geometry is spelled out rather than inlined.
    """
    y_far = cy + sign_y * radius
    draw.rectangle([cx, min(cy, y_far), cx + radius, max(cy, y_far)], fill=fill)
    draw.ellipse(
        [cx + radius - radius, y_far - radius, cx + radius + radius, y_far + radius],
        fill=BLACK,
    )


def _draw_mark(draw: "ImageDraw.ImageDraw", origin: float, extent: float) -> None:
    """Draw the mark into a square sub-region of the canvas.

    `origin` is the top-left offset in pixels, `extent` the side length. All
    interior geometry is expressed as a fraction of `extent`, so the same call
    renders the full-bleed and the maskable composition.
    """
    def p(v: float) -> float:
        return origin + v * extent

    r_bar = 0.065 * extent

    # LCARS "C" frame: one purple elbow running top-arm -> upright -> bottom
    # arm, with both concave corners filleted.
    _rr(draw, (p(0.100), p(0.105), p(0.290), p(0.895)), r_bar, PURPLE)   # upright
    _rr(draw, (p(0.100), p(0.105), p(0.520), p(0.250)), r_bar, PURPLE)   # top arm
    _rr(draw, (p(0.100), p(0.750), p(0.470), p(0.895)), r_bar, PURPLE)   # bottom arm
    _fillet(draw, p(0.290), p(0.250), 0.130 * extent, PURPLE, +1.0)
    _fillet(draw, p(0.290), p(0.750), 0.100 * extent, PURPLE, -1.0)

    # Companion rails. LCARS is never symmetrical; the gaps are the grammar.
    _rr(draw, (p(0.560), p(0.105), p(0.900), p(0.250)), r_bar, ORANGE)
    _rr(draw, (p(0.700), p(0.310), p(0.900), p(0.415)), 0.048 * extent, CYAN)
    _rr(draw, (p(0.520), p(0.790), p(0.900), p(0.895)), 0.048 * extent, CYAN)

    # Terminal prompt: chevron + underscore, in the open field of the frame.
    w = 0.056 * extent
    pts = [(0.400, 0.395), (0.560, 0.520), (0.400, 0.645)]
    draw.line([(p(x), p(y)) for x, y in pts],
              fill=PEACH, width=int(round(w)), joint="curve")
    # `joint="curve"` rounds the elbow of the polyline but leaves the two free
    # ends squared; cap all three vertices so the stroke reads as one shape.
    for cx, cy in pts:
        draw.ellipse([p(cx) - w / 2, p(cy) - w / 2, p(cx) + w / 2, p(cy) + w / 2],
                     fill=PEACH)
    _rr(draw, (p(0.610), p(0.590), p(0.880), p(0.648)), 0.029 * extent, PEACH)


def render(size: int, maskable: bool = False) -> "Image.Image":
    """Render one icon at `size` px, opaque RGB."""
    big = size * SS
    img = Image.new("RGB", (big, big), BLACK)
    draw = ImageDraw.Draw(img)
    if maskable:
        extent = big * 0.78
        origin = (big - extent) / 2.0
    else:
        extent = float(big)
        origin = 0.0
    _draw_mark(draw, origin, extent)
    return img.resize((size, size), Image.LANCZOS)


def main() -> int:
    out = Path(__file__).resolve().parent
    written = []

    for s in APPLE_SIZES:
        path = out / f"apple-touch-icon-{s}x{s}.png"
        render(s).save(path, "PNG", optimize=True)
        written.append(path)

    for s in MANIFEST_SIZES:
        path = out / f"icon-{s}.png"
        render(s).save(path, "PNG", optimize=True)
        written.append(path)

    for s in MASKABLE_SIZES:
        path = out / f"icon-maskable-{s}.png"
        render(s, maskable=True).save(path, "PNG", optimize=True)
        written.append(path)

    # Root-of-origin fallbacks. iOS probes these bare paths when a page
    # declares no <link rel="apple-touch-icon">; the 2026-08-26 device spike
    # caught ttyd logging requests for exactly these four (evaluation §7.1).
    # The cockpit page DOES declare its links, so these are belt-and-braces
    # for the case where a different LCARS page is added to the home screen.
    ui_root = out.parents[1]
    src180 = render(180)
    for name in (
        "apple-touch-icon.png",
        "apple-touch-icon-precomposed.png",
    ):
        path = ui_root / name
        src180.save(path, "PNG", optimize=True)
        written.append(path)
    src167 = render(167)
    for name in (
        "apple-touch-icon-167x167.png",
        "apple-touch-icon-167x167-precomposed.png",
    ):
        path = ui_root / name
        src167.save(path, "PNG", optimize=True)
        written.append(path)

    for path in written:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
