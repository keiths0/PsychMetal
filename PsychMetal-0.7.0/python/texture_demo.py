#!/usr/bin/env python3
"""Native Metal textures: upload once, draw many.

Python port of PsychMetalTextureDemo.m:

    python3 texture_demo.py            # 20 seconds
    python3 texture_demo.py 60

Click any mouse button to stop. Three things are on screen, all drawn by Metal:

  Left    a static RGB image, rotating, drawn from one uploaded texture.
  Middle  the SAME texture drawn three more times at different sizes and tints,
          to show that one upload serves many draws.
  Right   a counterphasing Gaussian blob that follows the mouse. It is uploaded
          ONCE and modulated by the tint alpha rather than re-uploaded per frame.

Re-uploading a texture every refresh is the usual way people animate contrast,
and the usual reason a stimulus loop misses frames. Here the pixels never
change: only the tint does, which is four floats per draw. Compare blob_demo.py,
which draws the same percept with no texture at all.

ORDERING is checked too: a yellow frame is drawn AFTER the left texture and
should appear on top of it.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm


def texture_demo(seconds=20):
    w, rect, ifi = pm.open_window(None)
    try:
        pm.hide_cursor()
        W, H = rect[2], rect[3]

        # An RGB image, built once. Rows are y, as in MATLAB's meshgrid.
        xx, yy = np.meshgrid(np.linspace(-1, 1, 256), np.linspace(-1, 1, 256))
        rr = np.sqrt(xx ** 2 + yy ** 2)
        img = np.stack([0.5 + 0.5 * np.sin(8 * xx), 0.5 + 0.5 * np.sin(8 * yy), np.maximum(0, 1 - rr)], axis=2)
        tex_rgb = pm.make_texture(w, img)

        # A Gaussian blob, uploaded once: white RGB with the envelope in alpha, so
        # contrast and sign come entirely from the tint at draw time.
        bx, by = np.meshgrid(np.linspace(-3, 3, 256), np.linspace(-3, 3, 256))
        gauss = np.exp(-(bx ** 2 + by ** 2) / 2)
        blob = np.dstack([np.ones_like(gauss)] * 3 + [gauss])
        tex_blob = pm.make_texture(w, blob)

        total = round(seconds / ifi)
        frames = 0
        t0 = pm.get_secs()
        side = min(W, H) * 0.22
        print('\nOne RGB texture drawn several times, plus a blob texture whose')
        print('contrast is animated by tint alone. Click to stop.')

        for k in range(total):
            sample = pm.get_secs()
            mx, my, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            frames = k + 1
            t = sample - t0
            pm.fill_rect(w, 128)

            # Left: rotating, full colour.
            cx, cy = W * 0.20, H * 0.5
            pm.draw_texture(w, tex_rgb, None, [cx - side, cy - side, cx + side, cy + side], t * 20)
            # Drawn AFTER the texture, so it must appear on top.
            pm.frame_rect(w, [255, 255, 0], [cx - side, cy - side, cx + side, cy + side], 4)

            # Middle: the same texture three more times, smaller and tinted, in
            # one call. modulate_colors is argument 8, after filter_modes and
            # global_alphas, as in Screen.
            j = np.arange(1, 4)
            s2 = side * (0.55 - 0.12 * j)
            mxc, myc = W * 0.50, H * (0.25 + 0.25 * j)
            pm.draw_textures(w, tex_rgb, None, [mxc - s2, myc - s2, mxc + s2, myc + s2], -t * 30, 1, None,
                             255 * np.array([np.ones(3), 1 - 0.3 * j, 0.3 * j, np.ones(3)]))

            # Right: contrast animated by tint alpha only, following the pointer
            # anywhere on screen, clamped only so that it stays wholly visible.
            c = 0.5 * math.sin(2 * math.pi * 1.0 * t)
            bx0 = min(max(mx, side), W - side)
            by0 = min(max(my, side), H - side)
            tint = [255, 255, 255, 255 * min(1, 2 * c)] if c >= 0 else [0, 0, 0, 255 * min(1, -2 * c)]
            pm.draw_texture(w, tex_blob, None, [bx0 - side, by0 - side, bx0 + side, by0 + side], 0, 1, None, tint)
            pm.flip(w)
        d = pm.diagnostic(w)
    finally:
        pm.close(w)
        pm.show_cursor()

    nn = min(frames, len(d['flipNumber']))
    # With and without a settling allowance; if these differ much, the run had not settled.
    warmup = min(120, round(nn / 3))
    st_all = pm.frame_stats(d, ifi)
    st = pm.frame_stats(d, ifi, warmup)
    s = d['summary']
    report = dict(ifi=ifi, frames=nn, achievedHz=st['achievedHz'], skipped=st['skipped'],
                  texturesCreated=s['texturesCreated'], texturesDrawn=s['texturesDrawn'], summary=s)
    print('\n===== native Metal textures =====')
    print(f"Textures created {report['texturesCreated']:.0f}; texture draws {report['texturesDrawn']:.0f} over "
          f"{nn} frames ({report['texturesDrawn'] / max(1, nn):.1f} per frame)")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s; skipped {report['skipped']}")
    print(f"       {st_all['achievedHz']:.3f}/s if the first {warmup} settling frames are kept "
          f"(skipped {st_all['skipped']})")
    if report['texturesCreated'] != 2:
        print('Expected exactly 2 uploads. More means something re-uploaded per frame.')
    print('The yellow frame is drawn after the left texture and should be on\n'
          'top of it. If it is underneath, call ordering is broken.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(texture_demo, args.seconds, threaded=args.threaded)


if __name__ == '__main__':
    main()
