"""Pre-render the launch Gabor/sigmoid with transparent fading edges; the app icon is unchanged.

Requires NumPy and Pillow only when regenerating the artwork, not at app launch.
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw


def main():
    out = Path(__file__).resolve().parents[1]/'resources'
    out.mkdir(exist_ok=True)
    n = 2048
    y, x = np.mgrid[0:n, 0:n].astype(np.float32)/(n-1)
    u, v = x-.5, y-.5
    radius = np.hypot(u, v)
    taper = np.clip((radius-.36)/(.49-.36), 0, 1)
    taper = 1-taper*taper*(3-2*taper)
    envelope = np.exp(-(u*u+v*v)/(2*.17**2))*taper
    carrier = u*np.cos(np.pi/10)+v*np.sin(np.pi/10)
    gray = 24+217*(.5+.5*np.cos(2*np.pi*5.3*carrier))
    rgb = np.repeat(np.clip(gray, 0, 255).astype('uint8')[:, :, None], 3, axis=2)
    rgba = np.dstack((rgb, np.uint8(np.clip(envelope*255, 0, 255))))
    image = Image.fromarray(rgba)
    draw = ImageDraw.Draw(image)
    xx = np.linspace(.16, .85, 400)
    yy = .76-.52/(1+np.exp(-15*(xx-.50)))
    points = [(int(a*n), int(b*n)) for a, b in zip(xx, yy)]
    draw.line(points, fill=(0, 0, 0, 255), width=int(n*.046), joint='curve')
    draw.line(points, fill=(255, 190, 72, 255), width=int(n*.025), joint='curve')
    for px, py in (points[0], points[-1]):
        r = int(n*.0125)
        draw.ellipse((px-r, py-r, px+r, py+r), fill=(255, 190, 72, 255))
    for size in (640, 1280, 1920):
        image.resize((size, size), Image.Resampling.LANCZOS).save(out/f'launch-{size}.png')
    print('Created launch-only artwork at 640/1280/1920 pixels; icon files unchanged.')


if __name__ == '__main__':
    main()
