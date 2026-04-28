#!/usr/bin/env python3
"""
Render the homefit.studio iOS app icon set.

Design: Option A — tight crop on the recognisable centre band of the
canonical matrix (2×2 coral circuit + sage rest, with the inner-most
pair of ghost pills flanking it for context). The full 48×9.5 matrix is
too wide (≈5:1) for a square icon; cropping to the centre slice keeps
the brand promise (the matrix IS the logo) while reading cleanly at the
smallest 60×60 home-screen size and the 1024×1024 marketing render.

Geometry is COPIED VERBATIM from the canonical sources:
  - app/lib/widgets/homefit_logo.dart            (Flutter)
  - web-portal/src/components/HomefitLogo.tsx    (TS)
  - web-player/app.js  buildHomefitLogoSvg()     (web)
Brand tokens copied from docs/design/project/tokens.json.

Outputs:
  app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png
plus a marketing PNG at the 1024×1024 size.

Run:
  python3 tools/icon-render/render_app_icon.py

No third-party deps beyond Pillow (already on Carl's Mac).
"""

from __future__ import annotations

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Brand tokens — mirror docs/design/project/tokens.json
# ---------------------------------------------------------------------------

CORAL = (0xFF, 0x6B, 0x35)        # color.brand.default
CORAL_TINT_ALPHA = 38             # ≈ 0.15 * 255 — coral band opacity
SAGE = (0x86, 0xEF, 0xAC)         # color.semantic.rest
GHOST_OUTER = (0x4B, 0x55, 0x63)  # ink.dark.disabled
GHOST_MID = (0x6B, 0x72, 0x80)    # ink.dark.muted
GHOST_INNER = (0x9C, 0xA3, 0xAF)  # ink.dark.secondary
SURFACE_BG = (0x0F, 0x11, 0x17)   # surface.dark.bg


# ---------------------------------------------------------------------------
# Canonical matrix geometry (48 × 9.5 source units)
# ---------------------------------------------------------------------------
# Verbatim from homefit_logo.dart / HomefitLogo.tsx / buildHomefitLogoSvg().

# (x, y, w, h, rx, fill)
PILLS = [
    # Left ghost pills: outer → inner
    (0.0,  2.75, 2.5, 1.5, 0.5, GHOST_OUTER),
    (4.0,  2.45, 3.5, 2.1, 0.7, GHOST_MID),
    (9.0,  2.15, 4.5, 2.7, 0.9, GHOST_INNER),
    # 2×2 coral circuit
    (15.0, 2.0,  5.0, 3.0, 1.0, CORAL),
    (15.0, 6.5,  5.0, 3.0, 1.0, CORAL),
    (21.5, 2.0,  5.0, 3.0, 1.0, CORAL),
    (21.5, 6.5,  5.0, 3.0, 1.0, CORAL),
    # Sage rest
    (28.0, 2.0,  5.0, 3.0, 1.0, SAGE),
    # Right ghost pills: inner → outer
    (34.5, 2.15, 4.5, 2.7, 0.9, GHOST_INNER),
    (40.5, 2.45, 3.5, 2.1, 0.7, GHOST_MID),
    (45.5, 2.75, 2.5, 1.5, 0.5, GHOST_OUTER),
]

# Coral tint band (sits behind the 2×2 circuit columns).
BAND = (14.5, 1.0, 12.5, 8.5, 1.2)  # x, y, w, h, rx


# ---------------------------------------------------------------------------
# Crop window — Option A (centre slice)
# ---------------------------------------------------------------------------
# The 48×9.5 matrix is too wide (~5:1) for a square icon. We crop to the
# centre slice that carries the brand promise:
#   inner ghost pill → 2×2 coral circuit (in tint band) → sage rest →
#   inner ghost pill (mirror)
#
# That's source x ∈ [9, 39], y ∈ [1, 9.5]  →  30 × 8.5  ≈ 3.5:1
# The matrix is rendered in the upper-middle, leaving the lower portion
# of the icon as a quiet field of dark surface — Apple's home-screen
# rounded mask means the corners get softly cropped anyway, and a
# centred-vertically band makes the icon feel composed at every size.
#
# Pills near the crop edges (the 9.0 / 34.5 inner ghosts) anchor the
# composition without trailing off into clipped fragments.

ICON_PX = 1024


def render_master() -> Image.Image:
    """Render the canonical 1024×1024 master icon."""
    # RGBA overlay — translucent coral band needs alpha compositing.
    img = Image.new("RGBA", (ICON_PX, ICON_PX), (*SURFACE_BG, 255))
    draw = ImageDraw.Draw(img)

    # Crop window in source units (centre slice of the canonical matrix).
    crop_x0, crop_y0, crop_x1, crop_y1 = 9.0, 1.0, 39.0, 9.5
    crop_w = crop_x1 - crop_x0
    crop_h = crop_y1 - crop_y0

    # Target the matrix to fill ~84% of the icon width. The home-screen
    # rounded-square mask trims roughly the outer 8% per side, so 84%
    # keeps the inner ghost pills (x=9, x=34.5) safely inside the visible
    # area while letting the coral 2×2 + sage rest dominate the icon.
    target_frac = 0.84
    target_w_px = ICON_PX * target_frac
    scale = target_w_px / crop_w  # source-unit → px

    rendered_h = crop_h * scale
    offset_x = (ICON_PX - target_w_px) / 2 - crop_x0 * scale
    offset_y = (ICON_PX - rendered_h) / 2 - crop_y0 * scale

    def to_px(x: float, y: float) -> tuple[float, float]:
        return (offset_x + x * scale, offset_y + y * scale)

    def draw_rounded_rect(d: ImageDraw.ImageDraw, sx: float, sy: float, sw: float,
                          sh: float, srx: float, fill) -> None:
        x0, y0 = to_px(sx, sy)
        x1, y1 = to_px(sx + sw, sy + sh)
        r_px = srx * scale
        d.rounded_rectangle(
            (round(x0), round(y0), round(x1), round(y1)),
            radius=max(1.0, r_px),
            fill=fill,
        )

    # NOTE: the canonical matrix has a 15%-coral tint band sitting behind
    # the 2×2 circuit. We omit it from the icon: at 60×60 the tint fills
    # the inter-pill gaps and the four coral cells read as one solid blob,
    # losing the 2×2 grid that's the recognisable bit of the matrix. The
    # band is decorative chrome on the web player / mobile preview surface
    # where the matrix is large enough for the gaps to win; an app icon
    # has to read at the smallest size first.

    # Pills — only those that overlap the crop window. Outer ghosts
    # (x=0, x=4, x=40.5, x=45.5) sit fully outside x ∈ [9, 39] and
    # are skipped so we don't spend pixels on partially-clipped marks.
    for (x, y, w, h, rx, fill) in PILLS:
        if x + w <= crop_x0 or x >= crop_x1:
            continue
        draw_rounded_rect(draw, x, y, w, h, rx, fill=(*fill, 255))

    return img.convert("RGB")


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

    # Marketing 1024 — exact master, no resampling.
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
