#!/usr/bin/env python3
"""
Render the homefit.studio iOS app icon set.

Design (v3): 2×2 coral circuit ONLY. Drops the ghost greys + sage rest +
tint band that v2 carried over from the matrix slice. The 2-cycle coral
circuit is the recognisable bit of the matrix; isolating it lets each
pill carry substantially more visual mass at the smallest 60×60 home
screen size while staying unmistakably "homefit.studio" at 1024×1024.

Geometry is COPIED VERBATIM from the canonical sources — the 4 coral
pills sit on a true 2×2 grid (top row + bottom row aligned, no stagger)
in the matrix logo:
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
SURFACE_BG = (0x0F, 0x11, 0x17)   # surface.dark.bg


# ---------------------------------------------------------------------------
# Canonical 2×2 coral circuit geometry (source units from the matrix logo)
# ---------------------------------------------------------------------------
# Verbatim from homefit_logo.dart / HomefitLogo.tsx / buildHomefitLogoSvg().
# The matrix is rendered in a 48×9.5 source viewbox; the 2×2 coral block
# occupies x ∈ [15, 26.5] and y ∈ [2, 9.5] within that. We render only
# those four pills here.

# (x, y, w, h, rx)
CORAL_PILLS = [
    (15.0, 2.0, 5.0, 3.0, 1.0),   # top-left
    (15.0, 6.5, 5.0, 3.0, 1.0),   # bottom-left
    (21.5, 2.0, 5.0, 3.0, 1.0),   # top-right
    (21.5, 6.5, 5.0, 3.0, 1.0),   # bottom-right
]


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

ICON_PX = 1024


def render_master() -> Image.Image:
    """Render the canonical 1024×1024 master icon — 2×2 coral circuit only."""
    img = Image.new("RGB", (ICON_PX, ICON_PX), SURFACE_BG)
    draw = ImageDraw.Draw(img)

    # v3 — Carl's call after v2: drop the ghost greys + sage rest, keep
    # only the 2×2 coral circuit. With four pills instead of seven the
    # individual coral cells get substantially more pixel area, which is
    # the whole point — readability at 60×60 was the bottleneck on v2.
    #
    # Target ~75% of canvas width for the coral cluster (within Carl's
    # 70-80% window). Centre on the actual pill bounding box, not the
    # source-viewbox window — the bounding box IS the composition.

    pill_x_min = min(p[0] for p in CORAL_PILLS)
    pill_x_max = max(p[0] + p[2] for p in CORAL_PILLS)
    pill_y_min = min(p[1] for p in CORAL_PILLS)
    pill_y_max = max(p[1] + p[3] for p in CORAL_PILLS)
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

    for (x, y, w, h, rx) in CORAL_PILLS:
        x0, y0 = to_px(x, y)
        x1, y1 = to_px(x + w, y + h)
        r_px = rx * scale
        draw.rounded_rectangle(
            (round(x0), round(y0), round(x1), round(y1)),
            radius=max(1.0, r_px),
            fill=CORAL,
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
