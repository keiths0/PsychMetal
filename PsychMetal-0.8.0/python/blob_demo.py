#!/usr/bin/env python3
"""A counterphasing Gaussian blob that follows the mouse.

Python port of PsychMetalBlobDemo.m:

    python3 blob_demo.py               # 20 s, 1 Hz, contrast 0.5
    python3 blob_demo.py 20 2 0.25     # 2 Hz, contrast 0.25

Click any mouse button to stop. A Gaussian luminance envelope on mid-grey,
oscillating sinusoidally between darker and brighter than the background.

NOT A TEXTURE. The envelope is evaluated per fragment, so there is no image to
upload and it is exact at any size. The shader puts the Gaussian in ALPHA, and
sign and amplitude come from the colour: for a signed contrast s on a 0.5
background, draw white when s > 0 and black when s < 0 with alpha 2|s|, and
blending over the grey gives 0.5 + s*gauss exactly.

Reports achieved rate and mouse-to-presentation latency.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm


def blob_demo(seconds=20, hz=1, contrast=0.5):
    if not 0 < contrast <= 0.5:
        raise ValueError('Contrast is the amplitude about mid-grey, so it must be in (0, 0.5].')
    w, rect, ifi = pm.open_window(None)
    try:
        pm.hide_cursor()
        sigma = 0.30                                  # fraction of the half-size
        half = min(rect[2], rect[3]) * 0.12           # about 3.3 sigma to the edge
        total = round(seconds / ifi)
        sample_time = np.full(total, np.nan)
        lum = np.full(total, np.nan)
        frames = 0
        t0 = pm.get_secs()
        print(f'\nGaussian blob, {hz:g} Hz counterphase, contrast {contrast:g}.')
        print('Move the mouse to reposition it. Click to stop.')
        for k in range(total):
            sample_time[k] = pm.get_secs()
            mx, my, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            frames = k + 1
            s = contrast * math.sin(2 * math.pi * hz * (sample_time[k] - t0))
            lum[k] = 0.5 + s
            x = min(max(mx, 0), rect[2])
            y = min(max(my, 0), rect[3])
            box = [x - half, y - half, x + half, y + half]
            pm.fill_rect(w, 128)                      # mid-grey field
            # Signed contrast: white above the background, black below. Alpha
            # carries twice the amplitude because blending halves it.
            if s >= 0:
                pm.draw_gabor(w, [255, 255, 255, min(255, 510 * s)], box, sigma)
            else:
                pm.draw_gabor(w, [0, 0, 0, min(255, -510 * s)], box, sigma)
            pm.flip(w)
        d = pm.diagnostic(w)
    finally:
        pm.close(w)
        pm.show_cursor()

    n = min(frames, len(d['flipNumber']))
    warmup = min(120, round(n / 3))
    st_all = pm.frame_stats(d, ifi)
    st = pm.frame_stats(d, ifi, warmup)
    ok = (d['actualStatus'][:n] == 0) & np.isfinite(d['actualTimestamp'][:n])
    input_ms = (d['actualTimestamp'][:n][ok] - sample_time[:n][ok]) * 1000
    median_ms = float(np.median(input_ms)) if input_ms.size else float('nan')
    report = dict(ifi=ifi, frames=n, hz=hz, contrast=contrast, sigma=sigma, achievedHz=st['achievedHz'],
                  skipped=st['skipped'], luminanceMin=float(np.nanmin(lum)) if frames else float('nan'),
                  luminanceMax=float(np.nanmax(lum)) if frames else float('nan'),
                  inputToPhotonsMedianMs=median_ms, inputToPhotonsRefreshes=median_ms / (ifi * 1000),
                  summary=d['summary'])
    print('\n===== Gaussian blob, drawn in Metal =====')
    print(f"Frames {n}; confirmed {int(ok.sum())}; skipped {report['skipped']}")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s")
    print(f"       {st_all['achievedHz']:.3f}/s if the first {warmup} settling frames are kept "
          f"(skipped {st_all['skipped']})")
    print(f"Luminance swept {report['luminanceMin']:.3f} to {report['luminanceMax']:.3f} about 0.5")
    print(f"MOUSE -> PRESENTED median {median_ms:.3f} ms ({report['inputToPhotonsRefreshes']:.3f} refreshes)")
    print('One instanced quad per frame for the blob; the envelope is evaluated\n'
          'in the fragment shader, so nothing is uploaded per frame.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('hz', nargs='?', type=float, default=1)
    parser.add_argument('contrast', nargs='?', type=float, default=0.5)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(blob_demo, args.seconds, args.hz, args.contrast, threaded=args.threaded)


if __name__ == '__main__':
    main()
