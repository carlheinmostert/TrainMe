#!/usr/bin/env python3
"""
Render the homefit.studio iOS app icon set.

Design (v5): same 3×3 grid as v4, but the CENTRE pill is sage
`#86EFAC` (the canonical brand rest colour) — the other 8 stay coral.
This mirrors the matrix logo's "circuit + rest" rhythm cue inside a
square footprint. Centre-pill choice is deliberate: bottom-right
would read as a sequential narrative (works in the wide matrix logo,
not in a square icon); centre is the most balanced, iconic placement.

Everything else identical to v4: pill geometry, canonical aligned-grid
spacing (dx=6.5, dy=4.5 in source units), dark surface, ~75% canvas
target width.

Geometry extends the canonical 2×2 from the matrix logo by adding a
third aligned row and column. The 2×2 lives at x ∈ {15, 21.5} and
y ∈ {2, 6.5}; v4 adds x = 28.0 and y = 11.0 to make 9 pills total.
Source-of-truth canonical spacing is documented in:
  - app/lib/widgets/homefit_logo.dart            (Flutter)
  - web-portal/src/components/HomefitLogo.tsx    (TS)
  - web-player/app.js  buildHomefitLogoSvg()     (web)
Brand tokens copied from docs/design/project/tokens.json.

Outputs:
  app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png

Run:
  python3 tools/icon-render/render_app_icon.py

No third-party deps beyond Pillow (already on Carl's Mac).
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Brand tokens — mirror docs/design/project/tokens.json
# ---------------------------------------------------------------------------

CORAL = (0xFF, 0x6B, 0x35)        # color.brand.default
SAGE = (0x86, 0xEF, 0xAC)         # color.rest — sage rest, distinct from accent
SURFACE_BG = (0x0F, 0x11, 0x17)   # surface.dark.bg


# ---------------------------------------------------------------------------
# 3×3 grid geometry (extends canonical 2×2 by one row + one column)
# ---------------------------------------------------------------------------
# Pill geometry verbatim from homefit_logo.dart / HomefitLogo.tsx /
# buildHomefitLogoSvg(): w=5.0, h=3.0, rx=1.0. Canonical aligned-grid
# spacing is dx=6.5 across columns and dy=4.5 across rows. The 2×2
# block sits at x ∈ {15.0, 21.5}, y ∈ {2.0, 6.5}; v4 adds x=28.0
# and y=11.0 for the third column and third row.
#
# v5: the centre cell — (COL_XS[1], ROW_YS[1]) — is rendered sage to
# echo the matrix logo's circuit+rest rhythm.

PILL_W = 5.0
PILL_H = 3.0
PILL_RX = 1.0
COL_XS = [15.0, 21.5, 28.0]   # dx = 6.5 (canonical)
ROW_YS = [2.0, 6.5, 11.0]     # dy = 4.5 (canonical)

# Centre of 3×3 — middle row, middle column.
SAGE_CELL = (COL_XS[1], ROW_YS[1])

# (x, y, w, h, rx, fill)
PILLS = [
    (x, y, PILL_W, PILL_H, PILL_RX, SAGE if (x, y) == SAGE_CELL else CORAL)
    for y in ROW_YS
    for x in COL_XS
]


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

ICON_PX = 1024


def render_master() -> Image.Image:
    """Render the canonical 1024×1024 master icon — 3×3 grid with centre sage (v5)."""
    img = Image.new("RGB", (ICON_PX, ICON_PX), SURFACE_BG)
    draw = ImageDraw.Draw(img)

    # v5 — same 3×3 grid as v4, but the centre pill is sage to mirror
    # the matrix logo's circuit+rest rhythm cue. Same target frac
    # (~75% of canvas width), same pill geometry, same canonical
    # aligned-grid spacing.
    #
    # Centre on the actual pill bounding box, not any source-viewbox
    # window — the bounding box IS the composition.

    pill_x_min = min(p[0] for p in PILLS)
    pill_x_max = max(p[0] + p[2] for p in PILLS)
    pill_y_min = min(p[1] for p in PILLS)
    pill_y_max = max(p[1] + p[3] for p in PILLS)
    pill_w = pill_x_max - pill_x_min  # 11.5 source units
    pill_h = pill_y_max - pill_y_min  # 7.5 source units

    target_frac = 0.75
    target_w_px = ICON_PX * target_frac
    scale = target_w_px / pill_w  # source-unit → px

    rendered_h_px = pill_h * scale
    offset_x = (ICON_PX - target_w_px) / 2 - pill_x_min * scale
    offset_y = (ICON_PX - rendered_h_px) / 2 - pill_y_min * scale

    def to_px(x: float, y: float) -> tuple[float, float]:
        return (offset_x + x * scale, offset_y + y * scale)

    for (x, y, w, h, rx, fill) in PILLS:
        x0, y0 = to_px(x, y)
        x1, y1 = to_px(x + w, y + h)
        r_px = rx * scale
        draw.rounded_rectangle(
            (round(x0), round(y0), round(x1), round(y1)),
            radius=max(1.0, r_px),
            fill=fill,
        )

    return img


# ---------------------------------------------------------------------------
# iOS icon set definition
# ---------------------------------------------------------------------------

# (filename, pixel size)
ICON_TARGETS = [
    ("Icon-App-1024x1024@1x.png", 1024),
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
]


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    out_dir = repo_root / "app" / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if not out_dir.is_dir():
        raise SystemExit(f"AppIcon.appiconset not found at {out_dir}")

    print(f"Rendering homefit.studio app icon master ({ICON_PX}×{ICON_PX})…")
    master = render_master()

    for filename, size in ICON_TARGETS:
        out_path = out_dir / filename
        if size == ICON_PX:
            master.save(out_path, format="PNG", optimize=True)
        else:
            resized = master.resize((size, size), Image.LANCZOS)
            resized.save(out_path, format="PNG", optimize=True)
        print(f"  → {filename}  ({size}×{size})")

    print(f"\nWrote {len(ICON_TARGETS)} PNGs to {out_dir.relative_to(repo_root)}")


if __name__ == "__main__":
    main()
