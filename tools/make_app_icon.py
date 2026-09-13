#!/usr/bin/env python3
"""Generate the NVMAI app icon.

The icon this replaces was the upstream turbo-fieldfare bird, which shipped as
the Mac app's Dock icon (issue #5). This draws an NVMAI mark instead, using the
same two brand colours as `assets/wordmark.svg` -- `NVM` in cyan `#0FB5CE`, `AI`
in orange `#E8820C` -- on a dark rounded square.

Deterministic and dependency-light: Pillow only, no SVG rasterizer. Re-run it to
regenerate the committed PNG:

    python3 tools/make_app_icon.py                     # writes the app resource
    python3 tools/make_app_icon.py /tmp/icon.png       # or anywhere

It is deliberately not wired into the build. The PNG is the committed asset
(`sources/NVMAIApp/Mac/Resources/nvmai-app-icon.png`, declared in
`Package.swift` and turned into a `.icns` by `tools/install_nvmai.sh`); this
script exists so the asset can be reproduced rather than being an opaque blob.

Requires `PIL` (`python3 -m pip install pillow`). Note that this is a *separate*
dependency from the converters' numpy/ml_dtypes/safetensors stack that
`tools/lib/python.sh` resolves, so it is not part of that search: it is a
one-off asset generator, not part of an install or a release.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "sources" / "NVMAIApp" / "Mac" / "Resources" / "nvmai-app-icon.png"

SIZE = 1024          # the committed asset's size
SUPERSAMPLE = 4      # drawn 4x and reduced, so the squircle edge is smooth
MARGIN = 100         # transparent gutter; the mark occupies 824x824 of 1024
RADIUS = 185         # macOS-style corner radius for that content box

CYAN = (15, 181, 206)     # #0FB5CE, the wordmark's "NVM"
ORANGE = (232, 130, 12)   # #E8820C, the wordmark's "AI"
BACKDROP_TOP = (18, 54, 66)
BACKDROP_BOTTOM = (6, 19, 26)

# Bold faces, best first. The wordmark is -apple-system 700; Avenir Next Bold is
# the closest geometric match that Pillow can load by path on a stock macOS.
FONT_CANDIDATES = (
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Avenir Next.ttc",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
)


def load_font(px: int) -> ImageFont.FreeTypeFont:
    """The first available bold face, preferring a named Bold variation."""
    last: Exception | None = None
    for path in FONT_CANDIDATES:
        if not Path(path).exists():
            continue
        try:
            font = ImageFont.truetype(path, px)
        except Exception as exc:  # pragma: no cover - environment dependent
            last = exc
            continue
        for name in ("Bold", "Semibold", "Heavy"):
            try:
                font.set_variation_by_name(name)
                break
            except Exception:
                continue
        return font
    raise SystemExit(f"no usable bold font found (tried {FONT_CANDIDATES}): {last}")


def gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """A vertical linear gradient, drawn one row at a time."""
    img = Image.new("RGB", (1, size))
    px = img.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    return img.resize((size, size), Image.NEAREST)


def squircle_mask(size: int, margin: int, radius: int) -> Image.Image:
    """An antialiased rounded-square mask via supersampled drawing."""
    big = size * SUPERSAMPLE
    m = margin * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (m, m, big - m, big - m), radius=radius * SUPERSAMPLE, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def draw_wordmark(canvas: Image.Image) -> None:
    """`NVM` in cyan and `AI` in orange, centred, auto-fitted to the content box."""
    inner = SIZE - 2 * MARGIN
    target_w = int(inner * 0.74)
    parts = (("NVM", CYAN), ("AI", ORANGE))

    font = load_font(100)
    for px in range(100, 460, 2):
        font = load_font(px)
        widths = [font.getbbox(t)[2] - font.getbbox(t)[0] for t, _ in parts]
        if sum(widths) > target_w:
            font = load_font(px - 2)
            break

    widths = [font.getbbox(t)[2] - font.getbbox(t)[0] for t, _ in parts]
    total = sum(widths)
    # Optical centring: use the cap height, not the line box, so the mark sits
    # in the middle of the square rather than slightly high.
    asc, desc = font.getmetrics()
    cap_top = min(font.getbbox(t)[1] for t, _ in parts)
    cap_bottom = max(font.getbbox(t)[3] for t, _ in parts)
    x = (SIZE - total) // 2
    y = (SIZE - (cap_bottom - cap_top)) // 2 - cap_top

    # A soft glow in the mark's own colours, so the letterforms read on the dark
    # backdrop without a hard outline.
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gx = x
    for (text, colour) in parts:
        gd.text((gx, y), text, font=font, fill=colour + (150,))
        gx += font.getbbox(text)[2] - font.getbbox(text)[0]
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(26)))

    draw = ImageDraw.Draw(canvas)
    gx = x
    for (text, colour) in parts:
        draw.text((gx, y), text, font=font, fill=colour + (255,))
        gx += font.getbbox(text)[2] - font.getbbox(text)[0]


def build() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = squircle_mask(SIZE, MARGIN, RADIUS)

    body = gradient(SIZE, BACKDROP_TOP, BACKDROP_BOTTOM).convert("RGBA")
    # A faint top-left sheen keeps the flat gradient from looking like a hole.
    sheen = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(sheen).ellipse(
        (-SIZE * 0.35, -SIZE * 0.75, SIZE * 1.05, SIZE * 0.55), fill=26
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(90))
    white = Image.new("L", (SIZE, SIZE), 255)
    body.alpha_composite(Image.merge("RGBA", (white, white, white, sheen)))

    draw_wordmark(body)

    # Clip to the rounded square, then add a hairline inner edge for depth.
    body.putalpha(mask)
    edge = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (MARGIN, MARGIN, SIZE - MARGIN - 1, SIZE - MARGIN - 1),
        radius=RADIUS, outline=(255, 255, 255, 26), width=3,
    )
    body.alpha_composite(edge)
    canvas.alpha_composite(body)
    return canvas


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    icon = build()
    icon.save(out, format="PNG", optimize=True)
    print(f"wrote {out} ({out.stat().st_size} bytes, {icon.width}x{icon.height} {icon.mode})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
