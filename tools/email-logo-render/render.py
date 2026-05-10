#!/usr/bin/env python3
"""Render the canonical homefit matrix logo as a PNG and inline it
into all 6 Supabase auth email templates as a base64 data URI.

Geometry mirrors the SVG in
`web-portal/src/components/HomefitLogo.tsx` byte-for-byte. Renders the
matrix-only variant (48×9.5 viewBox); the email header pairs this with
a separate text wordmark below, so we don't need the lockup variant
(which embeds Montserrat — a font we don't have at PNG render time).

Outputs:
  - web-portal/public/email/logo.png  (raw asset, also servable as a
    hosted URL once Vercel deploys)
  - supabase/email-templates/*.html   (header block updated with the
    inlined base64 data URI; same string in all 6)

Why base64 inline rather than a hosted URL? Lets the templates work
the moment they're applied to Supabase — no waiting for Vercel deploy.
~2.5KB extra per email is negligible. Fails in Outlook desktop only
(rare among this audience), where users see broken-image alt text.

Re-run after any geometry change in HomefitLogo.tsx and re-apply the
templates via the Management API one-liner in
`supabase/email-templates/README.md`.
"""

import base64
from pathlib import Path
from PIL import Image, ImageDraw

# Matrix viewBox dimensions
VW = 48
VH = 9.5

# 16x scale -> 768x152px PNG. Plenty for high-DPI email rendering;
# email clients downscale to display width (typically 240px wide).
SCALE = 16
W = int(VW * SCALE)
H = int(round(VH * SCALE))

# Email body bg — render against this so the 15%-opacity coral band
# composites cleanly. Email theme is dark; recipient theme can't change
# the email's own background.
BG = (15, 17, 23, 255)  # #0F1117


def hexrgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def rect(draw, x: float, y: float, w: float, h: float, r: float, fill: str, opacity: float = 1.0) -> None:
    rgb = hexrgb(fill)
    color = rgb + (int(round(opacity * 255)),)
    x0 = int(round(x * SCALE))
    y0 = int(round(y * SCALE))
    x1 = int(round((x + w) * SCALE))
    y1 = int(round((y + h) * SCALE))
    rad = int(round(r * SCALE))
    draw.rounded_rectangle([x0, y0, x1, y1], radius=rad, fill=color)


def render() -> Path:
    img = Image.new("RGBA", (W, H), BG)
    draw = ImageDraw.Draw(img, "RGBA")

    # Left ghost pills: outer -> inner, progressively larger + lighter
    rect(draw, 0,    2.75, 2.5,  1.5, 0.5, "#4B5563")
    rect(draw, 4,    2.45, 3.5,  2.1, 0.7, "#6B7280")
    rect(draw, 9,    2.15, 4.5,  2.7, 0.9, "#9CA3AF")

    # Coral tint band (15% opacity over the dark bg)
    rect(draw, 14.5, 1,    12.5, 8.5, 1.2, "#FF6B35", opacity=0.15)

    # 2x2 circuit grid in solid coral
    rect(draw, 15,   2,    5,    3,   1.0, "#FF6B35")
    rect(draw, 15,   6.5,  5,    3,   1.0, "#FF6B35")
    rect(draw, 21.5, 2,    5,    3,   1.0, "#FF6B35")
    rect(draw, 21.5, 6.5,  5,    3,   1.0, "#FF6B35")

    # Sage rest pill
    rect(draw, 28,   2,    5,    3,   1.0, "#86EFAC")

    # Right ghost pills (mirror of left)
    rect(draw, 34.5, 2.15, 4.5,  2.7, 0.9, "#9CA3AF")
    rect(draw, 40.5, 2.45, 3.5,  2.1, 0.7, "#6B7280")
    rect(draw, 45.5, 2.75, 2.5,  1.5, 0.5, "#4B5563")

    repo_root = Path(__file__).resolve().parent.parent.parent
    out = repo_root / "web-portal" / "public" / "email" / "logo.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "PNG", optimize=True)
    return out


OLD_HEADER = """<tr>
<td align="center" style="padding-bottom:40px;">
<span style="font-size:22px;font-weight:700;letter-spacing:0.01em;color:#FFFFFF;">homefit<span style="color:#FF6B35;">.studio</span></span>
</td>
</tr>"""


def new_header(b64: str) -> str:
    # Wordmark on top, matrix below — matches the canonical
    # HomefitLogoLockup layout. Wordmark is the primary brand
    # statement; matrix is the visual mark beneath it. If the matrix
    # image is blocked (e.g. Outlook desktop) the wordmark alone still
    # reads brand-correct. 200x40 display matches matrix viewBox 48x9.5
    # (5.05 aspect ratio); source PNG is 768x152 (~4x retina).
    return (
        '<tr>\n'
        '<td align="center" style="padding-bottom:4px;">\n'
        '<span style="font-size:22px;font-weight:700;letter-spacing:0.01em;color:#FFFFFF;">'
        'homefit<span style="color:#FF6B35;">.studio</span></span>\n'
        '</td>\n'
        '</tr>\n'
        '<tr>\n'
        '<td align="center" style="padding-bottom:20px;">\n'
        f'<img src="data:image/png;base64,{b64}" width="200" height="40" '
        'alt="homefit.studio" '
        'style="display:block;border:0;line-height:100%;outline:none;text-decoration:none;" />\n'
        '</td>\n'
        '</tr>'
    )


def inline_into_templates(png_path: Path) -> int:
    repo_root = png_path.resolve().parent.parent.parent.parent
    templates_dir = repo_root / "supabase" / "email-templates"
    if not templates_dir.exists():
        raise SystemExit(f"Templates dir missing: {templates_dir}")

    b64 = base64.b64encode(png_path.read_bytes()).decode("ascii")
    block = new_header(b64)

    files = sorted(templates_dir.glob("*.html"))
    updated = 0
    for f in files:
        text = f.read_text()
        if OLD_HEADER in text:
            f.write_text(text.replace(OLD_HEADER, block))
            print(f"  updated {f.name}")
            updated += 1
        elif "data:image/png;base64," in text:
            # already has an inlined logo — replace whichever order
            # the existing img+wordmark pair is in.
            import re
            img_row = (
                r'<tr>\s*<td align="center"[^>]*>\s*'
                r'<img[^>]*src="data:image/png;base64,[^"]+"[^/]*/>\s*'
                r'</td>\s*</tr>'
            )
            wordmark_row = (
                r'<tr>\s*<td align="center"[^>]*>\s*'
                r'<span style="font-size:\d+px[^"]*"[^>]*>'
                r'homefit<span style="color:#FF6B35;">\.studio</span></span>\s*'
                r'</td>\s*</tr>'
            )
            pattern = (
                rf'(?:{img_row}\s*{wordmark_row})|'
                rf'(?:{wordmark_row}\s*{img_row})'
            )
            updated_text = re.sub(
                pattern,
                block.replace('\\', r'\\'),
                text,
                count=1,
                flags=re.DOTALL,
            )
            if updated_text != text:
                f.write_text(updated_text)
                print(f"  refreshed {f.name}")
                updated += 1
            else:
                print(f"  SKIP {f.name} (couldn't match existing block)")
        else:
            print(f"  SKIP {f.name} (no header block found)")
    return updated


if __name__ == "__main__":
    out = render()
    size = out.stat().st_size
    print(f"Wrote {out} — {W}x{H}px, {size} bytes")
    n = inline_into_templates(out)
    print(f"Inlined into {n}/6 templates.")
