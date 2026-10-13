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
  * a texture updated on every frame, which must show that frame's image;
  * part of a texture replaced in place, the rest unchanged;
  * additive blending, which must sum and saturate;
  * linearization by a gamma and by a table, including that a half-alpha white
    over black comes out as half the light and not half the value;
  * a line of text: inside its rectangle, the right way up, in its colour;
  * an offscreen window: what is drawn into it comes back exactly when it is
    drawn to the window, draws into it accumulate, and its transparent part
    shows what is under it;
  * a partly transparent offscreen window: overlapping, soft-edged draws made
    through it match the same draws made on the window, half-alpha white is
    half white, and global alpha, a second offscreen window, a copied colour
    and the colour it was opened with all keep its transparency;
  * a clip rect, which must confine a draw to the pixel;
  * a filled polygon and a polygon's outline;
  * frames queued ahead: each is the frame that was drawn for it, and all are shown;
  * a second window at ten bits per channel, read back as 0..1023, with levels
    that fall between the 8-bit ones.

What this establishes is the rendered frame: the pixels the GPU handed to the
display. It says nothing about what the compositor or the panel did with them.

About six seconds. Every check is independent; a failure is recorded and the
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

    print('\npsychmetal readback test. About six seconds.\n')
    w, rect, ifi = pm.open_window(None, BACKGROUND, readback=True)
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

        # ---- part of a texture replaced in place -------------------------------------------------
        expected = np.full((TEXTURE_H, TEXTURE_W, 3), 240, dtype=np.uint8)       # as the loop left it
        expected[4:16, 8:24] = top[4:16, 8:24]
        pm.update_texture(w, t_live, top[4:16, 8:24], [8, 4, 24, 16])
        pm.draw_texture(w, t_live, None, dst, 0, 0)
        pm.flip(w)
        worst, _ = errors(pm.get_image(w, dst), expected)
        record('a partial update changes its rect and nothing else', worst == 0, f'largest error {worst:g} of 255')

        # ---- additive blending ----------------------------------------------------------------------
        pm.fill_rect(w, [100, 50, 200], dst)
        record('blend_function returns the old mode', pm.blend_function(w, 'add') == 'alpha')
        pm.fill_rect(w, [20, 30, 100], dst)
        pm.flip(w)
        got = pm.get_image(w, dst)
        record('additive blending sums and saturates', (got == [120, 80, 255]).all(), f'centre is {got[24, 32].tolist()}')
        pm.blend_function(w, 'alpha')
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.blend_function(w, 'add')
        pm.draw_texture(w, t_top, None, dst, 0, 0, 128)
        pm.blend_function(w, 'alpha')
        pm.flip(w)
        worst, mean = errors(pm.get_image(w, dst), np.minimum(bottom + top * (128 / 255), 255))
        record('an added texture at alpha 128/255 is bottom + alpha * top', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')

        # ---- linearization ----------------------------------------------------------------------------
        gamma = 2.2
        pm.linearize(w, gamma)
        pm.draw_texture(w, t_float, None, dst, 0, 0)
        pm.fill_rect(w, 0, [200, 24, 232, 56])
        pm.fill_rect(w, [255, 255, 255, 128], [200, 24, 232, 56])
        pm.flip(w)
        shot = pm.get_image(w)
        worst, mean = errors(shot[rows, cols], level.astype(np.float64) ** (1 / gamma) * 255)
        record('with a gamma, a linear value v is written as v ** (1 / gamma)', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')
        worst, _ = errors(shot[2, 2], (np.array(BACKGROUND) / 255) ** (1 / gamma) * 255)
        record('and so is the background', worst <= 1, f'{shot[2, 2].tolist()}')
        half = (128 / 255) ** (1 / gamma) * 255
        worst, _ = errors(shot[24:56, 200:232], half)
        record('half-alpha white over black is half the light', worst <= 1,
               f'{shot[40, 216].tolist()}, expected {half:.1f}; unlinearized it would be 128')
        steps = np.linspace(0, 1, 256)
        table = np.column_stack([np.sqrt(steps), steps, steps ** 2])
        pm.linearize(w, table)
        pm.draw_texture(w, t_float, None, dst, 0, 0)
        pm.flip(w)
        want = np.dstack([np.interp(level[:, :, c].astype(np.float64), steps, table[:, c]) for c in range(3)]) * 255
        worst, mean = errors(pm.get_image(w, dst), want)
        record('with a table, each channel follows its own column', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')
        pm.linearize(w, None)
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.flip(w)
        shot = pm.get_image(w)
        record('with linearization off again, frames are exact again',
               np.array_equal(shot[rows, cols], bottom) and (shot[2, 2] == bg).all())

        # ---- text ------------------------------------------------------------------------------------------
        size = 64
        bounds, ascent = pm.text_bounds(w, '^_', size)
        where, _ = pm.draw_text(w, '^_', 200, 100, [255, 255, 0], size)
        pm.flip(w)
        shot = pm.get_image(w)
        l, t, r, b = (int(v) for v in where)
        record('draw_text returns the rect that text_bounds measures',
               [l, t, r - l, b - t] == [200, 100, int(bounds[2]), int(bounds[3])] and 0 < ascent < bounds[3],
               f'{where.tolist()}, ascent {ascent:g}')
        ink = (shot[t:b, l:r] != bg).any(axis=2)
        outside = shot.copy()
        outside[t:b, l:r] = bg
        record('text marks pixels inside its rect and none outside', ink.any() and (outside == bg).all(),
               f'{int(ink.sum())} inside, {int((outside != bg).any(axis=2).sum())} outside')
        mid = (b - t) // 2
        upper, lower = np.nonzero(ink[:mid])[1], np.nonzero(ink[mid:])[1]
        record('"^_" has its caret above and to the left of its underscore',
               upper.size and lower.size and upper.mean() < lower.mean(),
               f'{upper.size} pixels above the middle, {lower.size} below')
        record('fully covered text pixels are exactly the text colour', (shot[t:b, l:r] == [255, 255, 0]).all(axis=2).any())

        # ---- an offscreen window ---------------------------------------------------------------------------
        off, off_rect = pm.open_offscreen_window(w, [0, 0, 0, 0], [0, 0, TEXTURE_W, TEXTURE_H])
        pm.draw_texture(off, t_bottom, None, [0, 0, TEXTURE_W, TEXTURE_H], 0, 0)
        pm.draw_texture(w, off, None, dst, 0, 0)
        pm.flip(w)
        worst, _ = errors(pm.get_image(w, dst), bottom)
        record('a texture drawn into an offscreen window comes back exactly', worst == 0, f'largest error {worst:g} of 255')
        patch = np.array([255, 128, 0], dtype=np.uint8)
        pm.fill_rect(off, patch, [8, 4, 24, 16])
        expected = bottom.copy()
        expected[4:16, 8:24] = patch
        pm.draw_texture(w, off, None, dst, 0, 0)
        pm.flip(w)
        worst, _ = errors(pm.get_image(w, dst), expected)
        record('draws into an offscreen window accumulate', worst == 0, f'largest error {worst:g} of 255')
        pm.blend_function(off, 'copy')
        pm.fill_rect(off, [0, 0, 0, 0])
        pm.blend_function(off, 'alpha')
        pm.fill_rect(off, patch, [8, 4, 24, 16])
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.draw_texture(w, off, None, dst, 0, 0)
        pm.flip(w)
        worst, _ = errors(pm.get_image(w, dst), expected)
        record('a transparent offscreen window shows what is under it', worst == 0, f'largest error {worst:g} of 255')

        # ---- a partly transparent offscreen window ------------------------------------------------------
        # What is drawn through an offscreen window must be what the same draws give
        # when made on the window itself, soft edges and overlaps included. The
        # window rounds to 8 bits after every draw and the offscreen window only
        # when it is drawn, so where layers overlap the two may differ by rounding.
        whole = [0, 0, TEXTURE_W, TEXTURE_H]

        def clear(target, colour=(0, 0, 0, 0)):
            pm.blend_function(target, 'copy')
            pm.fill_rect(target, colour)
            pm.blend_function(target, 'alpha')

        def layers(target, x, y):
            pm.fill_rect(target, [255, 255, 255, 128], [x + 4, y + 4, x + 40, y + 28])
            pm.fill_rect(target, [255, 128, 0, 64], [x + 24, y + 16, x + 60, y + 44])
            pm.fill_oval(target, [0, 255, 0, 200], [x + 2, y + 26, x + 30, y + 46])
            pm.draw_text(target, 'Ag', x + 34, y + 2, [255, 255, 0, 160], 14)

        def over_bottom(texture, alpha=None):
            pm.draw_texture(w, t_bottom, None, dst, 0, 0)
            pm.draw_texture(w, texture, None, dst, 0, 0, alpha)
            pm.flip(w)
            return pm.get_image(w, dst)

        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        layers(w, dst[0], dst[1])
        pm.flip(w)
        direct = pm.get_image(w, dst)
        clear(off)
        layers(off, 0, 0)
        through = over_bottom(off)
        worst, mean = errors(through, direct.astype(np.float64))
        record('partly transparent and soft-edged draws through an offscreen window match the same draws made directly',
               worst <= 2, f'largest difference {worst:g}, mean {mean:+.3f} of 255')
        a = 128 / 255
        under = bottom.astype(np.float64)
        alone = (slice(6, 14), slice(6, 22))                 # under the white rectangle and nothing else
        worst, mean = errors(through[alone], a * 255 + (1 - a) * under[alone])
        record('half-alpha white through an offscreen window is half white over what is under it', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')

        clear(off)
        pm.fill_rect(off, [255, 255, 255, 128], [0, 0, 32, TEXTURE_H])
        expected = under.copy()
        expected[:, :32] = a * a * 255 + (1 - a * a) * under[:, :32]
        worst, mean = errors(over_bottom(off, 128), expected)
        record('an offscreen window drawn with global alpha is everything in it at that alpha', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')

        off2, _ = pm.open_offscreen_window(w, [0, 0, 0, 0], whole)
        pm.draw_texture(off2, off, None, whole, 0, 0)
        expected[:, :32] = a * 255 + (1 - a) * under[:, :32]
        worst, mean = errors(over_bottom(off2), expected)
        record('an offscreen window drawn into another keeps its transparency', worst <= 1,
               f'largest error {worst:.2f}, mean error {mean:+.3f} of 255')
        pm.close(off2)

        clear(off, [255, 128, 0, 128])
        opened, _ = pm.open_offscreen_window(w, [255, 128, 0, 128], whole)
        expected = a * patch + (1 - a) * under
        worst = max(errors(over_bottom(off), expected)[0], errors(over_bottom(opened), expected)[0])
        record('a partly transparent colour copied into an offscreen window, or given when it is opened, is that colour at its alpha',
               worst <= 1, f'largest error {worst:.2f} of 255')
        pm.close(opened)
        pm.close(off)

        # ---- the clip rect ----------------------------------------------------------------------------------
        inner = [dst[0] + 10, dst[1] + 6, dst[0] + 40, dst[1] + 30]
        pm.draw_texture(w, t_bottom, None, dst, 0, 0)
        pm.clip(w, inner)
        pm.draw_texture(w, t_top, None, dst, 0, 0)
        pm.fill_rect(w, [255, 0, 255], [0, 0, 8, 8])              # wholly outside the clip
        pm.clip(w, None)
        pm.flip(w)
        expected = bottom.copy()
        expected[6:30, 10:40] = top[6:30, 10:40]
        shot = pm.get_image(w)
        worst, _ = errors(shot[rows, cols], expected)
        record('a clip rect confines a draw to the pixel', worst == 0 and (shot[4, 4] == bg).all(),
               f'largest error {worst:g} of 255; a draw outside the clip left {shot[4, 4].tolist()}')

        # ---- polygons -----------------------------------------------------------------------------------------
        pm.fill_poly(w, [255, 128, 0], [[100, 300], [200, 300], [100, 400]])          # a right triangle
        pm.frame_poly(w, [0, 255, 0], [[300, 300], [400, 300], [400, 400], [300, 400]], 5)
        pm.flip(w)
        shot = pm.get_image(w)
        record('a filled polygon is its colour inside and untouched outside',
               (shot[320:330, 110:120] == [255, 128, 0]).all() and (shot[385:395, 185:195] == bg).all(),
               f'inside {shot[325, 115].tolist()}, outside {shot[390, 190].tolist()}')
        record("a polygon's outline is drawn, and its inside left alone",
               (shot[300, 310:390] == [0, 255, 0]).all() and (shot[310:390, 300] == [0, 255, 0]).all()
               and (shot[320:380, 320:380] == bg).all(), f'edge {shot[300, 350].tolist()}, inside {shot[350, 350].tolist()}')

        # ---- frames queued ahead ---------------------------------------------------------------------------------
        t0 = pm.get_secs() + 0.25
        for k in range(4):
            pm.fill_rect(w, 50 * (k + 1), dst)
            pm.queue_flip(w, t0 + 2 * k * ifi)
        frames = pm.queue_results(w)
        got = pm.get_image(w, dst)
        record('queued frames are all shown', frames.shape == (4, 4) and (frames[:, 2] == 0).all(),
               f'status {frames[:, 2].astype(int).tolist()}')
        record('the last queued frame is the one drawn for it', (got == 200).all(), f'centre is {got[24, 32].tolist()}')
        pm.flip(w)
        record('and a flip after them shows a new frame', (pm.get_image(w, dst) == bg).all())
    finally:
        pm.show_cursor()
        pm.close(w)

    # ---- ten bits per channel: a window of its own ---------------------------------------------------------
    try:
        w, rect, _ = pm.open_window(None, BACKGROUND, readback=True, bit_depth=10)
    except pm.PsychMetalError as e:
        record('a 10-bit window opens', False, str(e))
    else:
        try:
            pm.hide_cursor()
            pm.fill_rect(w, [255, 0, 0], [10, 20, 110, 70])
            # Levels 384..639 of 1023: between the 8-bit levels, so 8 bits cannot hold them.
            ramp = np.tile(np.arange(384, 640, dtype=np.float32) / 1023, (4, 1))
            t_ramp = pm.make_texture(w, ramp)
            pm.draw_texture(w, t_ramp, None, [16, 100, 272, 104], 0, 0)
            pm.flip(w)
            shot = pm.get_image(w)
            record('a 10-bit frame is (height, width, 3) uint16',
                   shot.shape == (int(rect[3]), int(rect[2]), 3) and shot.dtype == np.uint16, f'{shot.shape} {shot.dtype}')
            want = np.round(np.array(BACKGROUND) / 255 * 1023)
            record('its background is the 0..1023 level of each channel', (shot[2, 2] == want).all(),
                   f'{shot[2, 2].tolist()}, expected {want.astype(int).tolist()}')
            record('red is in the first channel at 1023', (shot[20:70, 10:110] == [1023, 0, 0]).all(),
                   f'{shot[45, 60].tolist()}')
            got = shot[100:104, 16:272, 0].astype(np.int64)
            worst = int(np.abs(got - np.arange(384, 640)).max())
            record('256 consecutive 10-bit levels come back exactly', worst == 0,
                   f'largest error {worst} of 1023; {np.unique(got).size} distinct levels')
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
