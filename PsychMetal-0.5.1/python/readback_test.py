#!/usr/bin/env python3
"""Check what the GPU renders, pixel for pixel, by reading frames back.

Python port of PsychMetalReadbackTest.m:

    python3 readback_test.py              # run everything
    python3 readback_test.py --verbose    # print each check as it passes

The window is opened with readback, so every frame's drawable is copied before
it is presented and get_image returns those pixels. Each check draws something
whose result is known exactly, flips, reads the frame and compares:

  * the background, an opaque rectangle and its edges;
  * a uint8 texture at native size, which must come back bit for bit;
  * a float texture, within one grey level;
  * a masked texture over another: the overlay inside the mask and the
    original outside it, both exact;
  * a texture drawn with global alpha over another, against
    alpha * top + (1 - alpha) * bottom;
  * a texture updated on every frame, which must show that frame's image.

What this establishes is the rendered frame: the pixels the GPU handed to the
display. It says nothing about what the compositor or the panel did with them.

About two seconds. Every check is independent; a failure is recorded and the
run continues.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm

BACKGROUND = (51, 102, 153)
TEXTURE_H, TEXTURE_W = 48, 64


def pattern(a, b, c, d):
    """A fixed pseudo-random uint8 image, the same in MATLAB and Python."""
    y, x, k = np.meshgrid(np.arange(TEXTURE_H), np.arange(TEXTURE_W), np.arange(3), indexing='ij')
    return ((y * a + x * b + k * c + y * x * d) % 256).astype(np.uint8)


def readback_test(verbose=False):
    results = []

    def record(name, ok, detail=''):
        results.append(dict(name=name, ok=bool(ok), detail=detail))
        if verbose:
            print(f'  ok    {name}' + (f' ({detail})' if detail else '') if ok else f'  FAIL  {name}: {detail}')

    def errors(got, expected):
        """(largest absolute error, mean signed error), in grey levels of 255."""
        e = got.astype(np.float64) - expected
        return float(np.abs(e).max()), float(e.mean())

    print('\npsychmetal readback test. About two seconds.\n')
    w, rect, _ = pm.open_window(None, BACKGROUND, readback=True)
    try:
        pm.hide_cursor()
        width, height = int(rect[2]), int(rect[3])
        bg = np.array(BACKGROUND, dtype=np.uint8)
        dst = [16, 24, 16 + TEXTURE_W, 24 + TEXTURE_H]      # native size, whole pixels
        rows, cols = slice(dst[1], dst[3]), slice(dst[0], dst[2])
        bottom, top = pattern(73, 151, 199, 7), pattern(31, 17, 101, 3)

        # ---- the frame itself ----------------------------------------------------
        pm.flip(w)
        shot = pm.get_image(w)
        record('get_image returns (height, width, 3) uint8',
               shot.shape == (height, width, 3) and shot.dtype == np.uint8, f'{shot.shape} {shot.dtype}')
        record('an empty frame is the background everywhere', (shot == bg).all(),
               f'{int((shot != bg).any(axis=2).sum())} pixels differ')
        record('diagnostic reports readback', pm.diagnostic(w)['summary']['readbackEnabled'] is True)

        # ---- an opaque rectangle, and where it stops -------------------------------
        colour = np.array([255, 128, 0], dtype=np.uint8)
        pm.fill_rect(w, colour, [10, 20, 110, 70])
        pm.flip(w)
        shot = pm.get_image(w)
        record('an opaque rectangle has exactly its colour', (shot[20:70, 10:110] == colour).all(),
               f'centre is {shot[45, 60].tolist()}')
        outside = shot.copy()
        outside[20:70, 10:110] = bg
        record('pixels outside the rectangle are untouched', (outside == bg).all(),
               f'{int((outside != bg).any(axis=2).sum())} pixels differ')
        part = pm.get_image(w, [5, 15, 120, 80])
        record('get_image with a rect is that part of the frame',
               part.shape == (65, 115, 3) and np.array_equal(part, shot[15:80, 5:120]), f'{part.shape}')

        # ---- textures at native size ---------------------------------------------------
        t_bottom, t_top = pm.make_texture(w, bottom), pm.make_texture(w, top)
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.flip(w)
        worst, mean = errors(pm.get_image(w, dst), bottom)
        record('a uint8 texture comes back bit for bit', worst == 0, f'largest error {worst:g} of 255')

        level = pattern(11, 29, 53, 5).astype(np.float32) / 255 * 0.999 + 0.0004     # not on the 8-bit grid
        t_float = pm.make_texture(w, level)
        pm.draw_texture(w, t_float, None, dst, 0, 0)
        pm.flip(w)
        worst, mean = errors(pm.get_image(w, dst), level.astype(np.float64) * 255)
        record('a float texture is within one grey level', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')

        # ---- a masked texture over another -----------------------------------------------
        y, x = np.ogrid[:TEXTURE_H, :TEXTURE_W]
        mask = (y - TEXTURE_H / 2) ** 2 + (x - TEXTURE_W / 2) ** 2 < 20 ** 2
        t_masked = pm.make_texture(w, np.dstack([top, np.where(mask, 255, 0).astype(np.uint8)]))
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.draw_texture(w, t_masked, None, dst, 0, 0)
        pm.flip(w)
        got = pm.get_image(w, dst)
        record('inside the mask is the overlay, exactly', np.array_equal(got[mask], top[mask]),
               f'largest error {errors(got[mask], top[mask])[0]:g} of 255')
        record('outside the mask is the texture underneath, exactly', np.array_equal(got[~mask], bottom[~mask]),
               f'largest error {errors(got[~mask], bottom[~mask])[0]:g} of 255')

        # ---- global alpha blends over what is underneath ------------------------------------
        for alpha in (64, 128, 191):
            pm.draw_texture(w, t_bottom, None, dst, 0, 0)
            pm.draw_texture(w, t_top, None, dst, 0, 0, alpha)
            pm.flip(w)
            a = alpha / 255
            worst, mean = errors(pm.get_image(w, dst), a * top + (1 - a) * bottom)
            record(f'global alpha {alpha}/255 is alpha * top + (1 - alpha) * bottom', worst <= 1,
                   f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')

        # ---- a texture updated on every frame ---------------------------------------------------
        t_live = pm.make_texture(w, np.zeros((TEXTURE_H, TEXTURE_W, 3), dtype=np.uint8))
        wrong = []
        for frame in range(1, 13):
            pm.update_texture(w, t_live, np.full((TEXTURE_H, TEXTURE_W, 3), frame * 20, dtype=np.uint8))
            pm.draw_texture(w, t_live, None, dst, 0, 0)
            pm.flip(w)
            if not (pm.get_image(w, dst) == frame * 20).all():
                wrong.append(frame)
        record('a texture updated every frame shows that frame\'s image', not wrong,
               f'frames {wrong} showed another image' if wrong else '12 frames')
        surround = pm.get_image(w)
        surround[rows, cols] = bg
        record('outside the texture, the frame is still the background', (surround == bg).all(),
               f'{int((surround != bg).any(axis=2).sum())} pixels differ')
    finally:
        pm.show_cursor()
        pm.close(w)

    failed = [r for r in results if not r['ok']]
    print('===== readback =====')
    print(f'{len(results)} checks: {len(results) - len(failed)} passed, {len(failed)} failed.')
    if failed:
        print('\nFailures:')
        for r in failed:
            print(f"  {r['name']:<58} {r['detail']}")
    else:
        print('Every frame read back as drawn.')
    return dict(checks=len(results), passed=len(results) - len(failed), failed=len(failed), results=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--verbose', action='store_true', help='print each check as it passes')
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    report = pm.run(readback_test, args.verbose, threaded=args.threaded)
    raise SystemExit(1 if report['failed'] else 0)


if __name__ == '__main__':
    main()
