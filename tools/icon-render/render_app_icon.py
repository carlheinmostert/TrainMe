#!/usr/bin/env python3
"""
Render the homefit.studio iOS app icon set.

Design (v7): 3×3 grid + sage centre, with SQUARE pills (5×5) so the
bounding box is a true 1:1 block on a phone home screen.

Why v7 — and the deliberate brand divergence: pills are canonical
5×3 (5 wide, 3 tall) in the matrix logo across web and mobile. With
canonical pills, a 3×3 grid can never form a square bounding box at
any reasonable spacing — v5 (dy=4.5) gave an 18×12 stripe (3:2),
and v6 (dy=5.5) bumped that to 18×14 (1.29:1). Carl tested v6 on
his iPhone home screen and reported it STILL read wider than tall.
Comparing four candidates (square via vertical gaps, square pills,
square + bigger pills, rotate to vertical pills), Carl picked
"square pills, bigger" — break the canonical 5:3 aspect ratio in
the icon surface ONLY so the grid is a clean 1:1 block.

This is a deliberate, scoped brand divergence: the matrix logo
elsewhere (Flutter app, web portal, web player) keeps its canonical
5:3 pills. The icon surface gets square pills because a square
bounding box is load-bearing for an iOS app icon. Standard practice
for app icons — geometry adapts to the square frame; the rest of
the brand system stays intact.

v7 geometry: PILL_H raised 3.0 → 5.0 (square 5×5), and ROW_YS
spaced dy=6.5 (was dy=5.5) so the vertical gap between pills
matches the horizontal gap. Bounding box becomes 18 wide × 18 tall
— a true 1:1 square block. Horizontal cadence dx=6.5 unchanged.

Centre pill stays sage `#86EFAC` — the centre-sage composition
mirrors the matrix logo's "circuit + rest" rhythm cue inside a
square footprint. Centre placement is the most balanced, iconic
choice; bottom-right would read as a sequential narrative (works
in the wide matrix logo, not in a square icon).

Unchanged from v6: pill colours (coral + sage), pill rx=1, dark
surface `#0F1117`, ~75% canvas target width, dx=6.5 horizontal
cadence, COL_XS unchanged.

Source-of-truth canonical spacing is documented in:
  - app/lib/widgets/homefit_logo.dart            (Flutter)
  - web-portal/src/components/HomefitLogo.tsx    (TS)
  - web-player/app.js  buildHomefitLogoSvg()     (web)
Those three sites keep canonical 5:3 pills; the divergence is
scoped to this renderer / the iOS icon set only.
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
# 3×3 grid geometry (icon-only divergence: square pills, true 1:1 block)
# ---------------------------------------------------------------------------
# v7: PILL_H raised 3.0 → 5.0 — square pills, breaking the canonical
# 5:3 aspect ratio ON THE ICON SURFACE ONLY. The matrix logo on web
# and mobile keeps the canonical 5×3 pills (homefit_logo.dart /
# HomefitLogo.tsx / buildHomefitLogoSvg()); a 3×3 grid of those can't
# form a 1:1 bounding box at reasonable spacing, and Carl tested v6
# (dy=5.5, 1.29:1 box) on device — it still read wider than tall.
# Square pills give a clean 1:1 grid block, which is load-bearing for
# an iOS app icon.
#
# Horizontal cadence dx=6.5 unchanged, so COL_XS is also unchanged.
# Vertical cadence raised dy=5.5 → 6.5 so the inter-row gap matches
# the inter-column gap (1.5 source units in both axes with 5×5
# pills). Third row therefore sits at y=15.0 (was 13.0 in v6, 11.0
# in v5).
#
# Bounding box: 18 wide (3×dx + pill_w − dx = 3·6.5 + 5 − 6.5 = 18)
#             × 18 tall (3×dy + pill_h − dy = 3·6.5 + 5 − 6.5 = 18)
# — a true 1:1 square.
#
# Centre cell (COL_XS[1], ROW_YS[1]) is rendered sage to echo the
# matrix logo's circuit+rest rhythm.

PILL_W = 5.0
PILL_H = 5.0                   # v7: square pills (was 3.0) — icon-only divergence from canonical 5:3
PILL_RX = 1.0
COL_XS = [15.0, 21.5, 28.0]    # dx = 6.5 (canonical, unchanged)
ROW_YS = [2.0, 8.5, 15.0]      # dy = 6.5 (v7: raised from 5.5 so vertical gap matches horizontal)

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
    """Render the canonical 1024×1024 master icon — 3×3 grid with centre sage (v7)."""
    img = Image.new("RGB", (ICON_PX, ICON_PX), SURFACE_BG)
    draw = ImageDraw.Draw(img)

    # v7 — square 5×5 pills give a true 1:1 bounding box (18×18 in
    # source units). Carl's v6 device test still read wider-than-tall
    # because canonical 5:3 pills can't form a square grid at any
    # reasonable spacing; v7 abandons the canonical pill aspect on
    # this icon surface only so the matrix lands as a clean square
    # block. Same target frac (~75% of canvas width), same horizontal
    # dx=6.5, same coral / sage / dark surface tokens.
    #
    # Centre on the actual pill bounding box, not any source-viewbox
    # window — the bounding box IS the composition.

    pill_x_min = min(p[0] for p in PILLS)
    pill_x_max = max(p[0] + p[2] for p in PILLS)
    pill_y_min = min(p[1] for p in PILLS)
    pill_y_max = max(p[1] + p[3] for p in PILLS)
    pill_w = pill_x_max - pill_x_min  # 18.0 source units (3 cols × dx 6.5 + pill 5.0 - dx)
    pill_h = pill_y_max - pill_y_min  # 18.0 source units (v7: 2 × dy 6.5 + pill 5.0 — square)

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
