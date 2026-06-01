#!/usr/bin/env python3
"""Generate Lyrify's app icon: a dark squircle showing lyric lines with one
highlighted in Spotify green — a literal nod to what the app does.

Renders a 1024×1024 PNG, expands it into an .iconset, and runs `iconutil`
to produce app/AppIcon.icns. Re-run after tweaking the design.
"""
import os
import subprocess
import tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024

# Palette
GREEN = (29, 185, 84, 255)      # Spotify green — the "active" lyric line
DIM = (74, 74, 74, 255)         # inactive lyric lines
BG_TOP = (26, 26, 26, 255)
BG_BOTTOM = (10, 10, 10, 255)


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    margin = int(size * 0.097)  # leave the transparent margin macOS expects
    d.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius, fill=255,
    )
    return mask


def vertical_gradient(size, top, bottom):
    # Fill a single column with the gradient, then stretch it horizontally.
    column = Image.new("RGBA", (1, size))
    px = column.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4))
    return column.resize((size, size))


def main():
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = vertical_gradient(SIZE, BG_TOP, BG_BOTTOM)
    icon.paste(bg, (0, 0), rounded_mask(SIZE, int(SIZE * 0.205)))

    draw = ImageDraw.Draw(icon)

    # Five "lyric lines": left-aligned bars, one highlighted green.
    # widths as fraction of the inner content width; index 2 is active.
    widths = [0.62, 0.80, 0.70, 0.86, 0.54]
    active = 2
    left = int(SIZE * 0.26)
    content_w = int(SIZE * 0.50)
    bar_h = int(SIZE * 0.062)
    gap = int(SIZE * 0.055)
    total_h = len(widths) * bar_h + (len(widths) - 1) * gap
    top = (SIZE - total_h) // 2

    for i, frac in enumerate(widths):
        y0 = top + i * (bar_h + gap)
        w = int(content_w * frac)
        is_active = i == active
        h = int(bar_h * (1.15 if is_active else 1.0))
        y0 -= (h - bar_h) // 2
        color = GREEN if is_active else DIM
        draw.rounded_rectangle(
            [left, y0, left + w, y0 + h],
            radius=h // 2, fill=color,
        )

    png_path = os.path.join(HERE, "icon-1024.png")
    icon.save(png_path)
    print(f"wrote {png_path}")

    # Build the .iconset and convert with iconutil.
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        specs = [
            (16, "16x16"), (32, "16x16@2x"),
            (32, "32x32"), (64, "32x32@2x"),
            (128, "128x128"), (256, "128x128@2x"),
            (256, "256x256"), (512, "256x256@2x"),
            (512, "512x512"), (1024, "512x512@2x"),
        ]
        for px, name in specs:
            icon.resize((px, px), Image.LANCZOS).save(
                os.path.join(iconset, f"icon_{name}.png")
            )
        out = os.path.join(HERE, "AppIcon.icns")
        subprocess.run(
            ["iconutil", "-c", "icns", iconset, "-o", out], check=True
        )
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
