"""Generate MewSify app icons.

Run from the project root:
    python3 tools/generate_icon.py

Produces a polished, professional logo:
  - Rounded square dark background with a subtle gradient
  - Bright green-to-teal gradient on the central mark
  - Sound-wave / equalizer bars forming an "M"-like silhouette
  - Soft inner glow + drop shadow for depth

Outputs:
    assets/images/app_icon.png            (1024x1024 full icon, iOS)
    assets/images/app_icon_foreground.png (1024x1024 transparent fg, Android adaptive)

After running this:
    flutter pub run flutter_launcher_icons
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
BG_TOP = (15, 15, 20, 255)
BG_BOTTOM = (28, 28, 36, 255)

ACCENT_TOP = (29, 233, 124, 255)   # bright green (Spotify-ish)
ACCENT_MID = (29, 200, 153, 255)
ACCENT_BOTTOM = (10, 160, 175, 255)  # teal


def gradient_fill(size, top, bottom, vertical=True):
    """Linear gradient image."""
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        t = y / max(1, size - 1) if vertical else 0
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        a = int(top[3] + (bottom[3] - top[3]) * t)
        for x in range(size):
            px[x, y] = (r, g, b, a)
    return img


def rounded_mask(size, radius_ratio=0.22):
    radius = int(size * radius_ratio)
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=radius, fill=255)
    return mask


def draw_eq_bars(image, color_top, color_bottom, scale=1.0):
    """Draw a row of stylised equalizer bars centered on the canvas.

    Bar heights form an upward-then-downward sweep, suggestive of an
    "M" silhouette while reading clearly as a music symbol.
    """
    draw = ImageDraw.Draw(image)
    cx, cy = SIZE // 2, SIZE // 2

    # 7 bars with curated heights. The middle bar is shortest so the
    # silhouette resembles an M.
    bar_heights = [0.45, 0.75, 0.95, 0.55, 0.95, 0.75, 0.45]
    num = len(bar_heights)
    bar_width = int(54 * scale)
    spacing = int(28 * scale)
    total_width = num * bar_width + (num - 1) * spacing
    start_x = cx - total_width // 2

    max_h = int(420 * scale)
    base_y = cy + int(180 * scale)

    for i, h_ratio in enumerate(bar_heights):
        h = int(max_h * h_ratio)
        x0 = start_x + i * (bar_width + spacing)
        y0 = base_y - h
        x1 = x0 + bar_width
        y1 = base_y

        # Per-bar gradient (top brighter, bottom richer)
        for y in range(y0, y1):
            t = (y - y0) / max(1, h)
            r = int(color_top[0] + (color_bottom[0] - color_top[0]) * t)
            g = int(color_top[1] + (color_bottom[1] - color_top[1]) * t)
            b = int(color_top[2] + (color_bottom[2] - color_top[2]) * t)
            draw.rectangle([(x0, y), (x1, y + 1)], fill=(r, g, b, 255))
        # Rounded ends
        draw.ellipse([(x0, y0 - bar_width // 2), (x1, y0 + bar_width // 2)],
                     fill=color_top)
        draw.ellipse([(x0, y1 - bar_width // 2), (x1, y1 + bar_width // 2)],
                     fill=color_bottom)


def with_drop_shadow(layer, blur=14, offset=(0, 6), opacity=140):
    """Returns a (shadow + layer) image, both transparent-friendly."""
    shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sa = layer.split()[3]
    shadow.paste((0, 0, 0, opacity), mask=sa)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.alpha_composite(shadow, dest=offset)
    out.alpha_composite(layer)
    return out


def main():
    out_dir = os.path.join(os.path.dirname(__file__), "..", "assets", "images")
    os.makedirs(out_dir, exist_ok=True)

    # ---------- iOS-style full icon ----------
    bg = gradient_fill(SIZE, BG_TOP, BG_BOTTOM)
    rmask = rounded_mask(SIZE)
    bg.putalpha(rmask)

    # Subtle vignette (radial darkening on edges)
    vign = Image.new("L", (SIZE, SIZE), 0)
    vd = ImageDraw.Draw(vign)
    inset = int(SIZE * 0.12)
    vd.ellipse([(inset, inset), (SIZE - inset, SIZE - inset)], fill=255)
    vign = vign.filter(ImageFilter.GaussianBlur(60))
    vign_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    # Brighten the center slightly with a soft accent glow.
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    glow_size = int(SIZE * 0.65)
    gx0 = (SIZE - glow_size) // 2
    gy0 = (SIZE - glow_size) // 2
    gd.ellipse([(gx0, gy0), (gx0 + glow_size, gy0 + glow_size)],
               fill=(ACCENT_MID[0], ACCENT_MID[1], ACCENT_MID[2], 60))
    glow = glow.filter(ImageFilter.GaussianBlur(80))
    bg.alpha_composite(glow)

    # Equalizer mark in its own layer so we can drop-shadow it.
    bars = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_eq_bars(bars, ACCENT_TOP, ACCENT_BOTTOM, scale=1.0)
    bars = with_drop_shadow(bars, blur=22, offset=(0, 12), opacity=180)
    bg.alpha_composite(bars)

    bg.save(os.path.join(out_dir, "app_icon.png"), format="PNG")

    # ---------- Android adaptive foreground ----------
    # Just the mark, sized smaller so the system mask doesn't clip it.
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    # Inner accent disc behind the bars for a more recognizable shape
    disc_color = (
        int(ACCENT_TOP[0] * 0.4),
        int(ACCENT_TOP[1] * 0.4),
        int(ACCENT_TOP[2] * 0.4),
        180,
    )
    fg_d = ImageDraw.Draw(fg)
    pad = int(SIZE * 0.22)
    fg_d.ellipse([(pad, pad), (SIZE - pad, SIZE - pad)], fill=disc_color)
    bars2 = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_eq_bars(bars2, ACCENT_TOP, ACCENT_BOTTOM, scale=0.85)
    bars2 = with_drop_shadow(bars2, blur=16, offset=(0, 8), opacity=160)
    fg.alpha_composite(bars2)
    fg.save(os.path.join(out_dir, "app_icon_foreground.png"), format="PNG")

    print("Wrote:")
    print(" ", os.path.realpath(os.path.join(out_dir, "app_icon.png")))
    print(" ", os.path.realpath(os.path.join(out_dir, "app_icon_foreground.png")))


if __name__ == "__main__":
    main()
