"""Generate the small notification icon used by audio_service.

Android requires the small (status-bar / lock-screen) icon to be a
monochrome white silhouette on a transparent background — colored
icons render as a blank white blob.

Outputs at every density Android needs:
    drawable-mdpi      24x24
    drawable-hdpi      36x36
    drawable-xhdpi     48x48
    drawable-xxhdpi    72x72
    drawable-xxxhdpi   96x96
"""
import os
from PIL import Image, ImageDraw

# Targets: density bucket -> base size in px (24dp at that density).
DENSITIES = [
    ('drawable-mdpi', 24),
    ('drawable-hdpi', 36),
    ('drawable-xhdpi', 48),
    ('drawable-xxhdpi', 72),
    ('drawable-xxxhdpi', 96),
]


def draw_mark(size: int) -> Image.Image:
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Render the icon at 4x for crisp downscaling.
    scale = 4
    big = Image.new('RGBA', (size * scale, size * scale), (0, 0, 0, 0))
    bd = ImageDraw.Draw(big)

    bar_count = 5
    margin = size * scale * 0.18
    avail = size * scale - margin * 2
    bar_w = avail / (bar_count * 2 - 1)
    spacing = bar_w
    heights = [0.45, 0.75, 1.0, 0.7, 0.5]
    cy = size * scale / 2
    max_h = (size * scale - margin * 2) * 0.7
    start_x = margin

    for i in range(bar_count):
        h = max_h * heights[i]
        x = start_x + i * (bar_w + spacing)
        y = cy - h / 2
        # Rounded rectangle
        bd.rounded_rectangle(
            [(x, y), (x + bar_w, y + h)],
            radius=bar_w / 2,
            fill=(255, 255, 255, 255),
        )

    # Smooth downscale.
    return big.resize((size, size), Image.LANCZOS)


def main():
    base = os.path.join(os.path.dirname(__file__), '..', 'android', 'app',
                        'src', 'main', 'res')
    for folder, sz in DENSITIES:
        path = os.path.join(base, folder)
        os.makedirs(path, exist_ok=True)
        img = draw_mark(sz)
        out = os.path.join(path, 'ic_notification.png')
        img.save(out, format='PNG')
        print(f'  wrote {out}')


if __name__ == '__main__':
    main()
