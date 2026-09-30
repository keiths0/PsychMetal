#!/usr/bin/env python3
"""Drifting Gabors, computed in the shader, never uploaded.

Python port of PsychMetalGaborDemo.m:

    python3 gabor_demo.py                    # 20 s, 12 Gabors, 2 Hz drift
    python3 gabor_demo.py 20 1               # one large Gabor
    python3 gabor_demo.py 20 48 4            # 48 of them, 4 Hz
    python3 gabor_demo.py 20 12 2 0.04

Click any mouse button to stop. Arguments: seconds, number of Gabors, temporal
frequency in Hz, carrier spatial frequency in cycles per pixel (0 gives a plain
Gaussian). The phase advances with PRESENTED TIME, not the frame counter, so the
drift rate stays correct across a dropped frame.

Both the Gaussian envelope and the carrier are evaluated per fragment in
PsychMetal's shader: nothing is uploaded, the envelope is exact at any size, and
all patches go to the GPU as one instanced draw.

In Python each draw_gabor call also costs tens of microseconds of argument
handling. Orientation is one value per call, so this demo makes one call per
patch, as the MATLAB version does; at a few hundred patches that CPU cost, not
the GPU, is what limits the rate.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm


def gabor_demo(seconds=20, n_gabors=12, tf=2, freq=0.02):
    if n_gabors < 1:
        raise ValueError('n_gabors must be at least 1.')
    if freq < 0:
        raise ValueError('Frequency must be zero or positive.')
    # Mid-grey background, set once at open: each frame is cleared to it free.
    w, rect, ifi = pm.open_window(None, 128)
    try:
        pm.hide_cursor()
        W, H = rect[2], rect[3]
        sigma = 0.30                     # envelope width, fraction of the half-size

        # As square a grid as the count allows, patches sized to the cell.
        if n_gabors == 1:
            cols = rows = 1
            half = min(W, H) * 0.35
            cxs, cys = np.array([W / 2]), np.array([H / 2])
        else:
            cols = math.ceil(math.sqrt(n_gabors * W / H))
            rows = math.ceil(n_gabors / cols)
            cell_w, cell_h = W / cols, H / rows
            half = min(cell_w, cell_h) * 0.45
            # MATLAB's meshgrid(1:cols, 1:rows)(:) runs down each column first.
            gi, gj = np.meshgrid(np.arange(1, cols + 1), np.arange(1, rows + 1))
            cxs = ((gi.ravel(order='F') - 0.5) * cell_w)[:n_gabors]
            cys = ((gj.ravel(order='F') - 0.5) * cell_h)[:n_gabors]

        # One orientation per patch over half a turn: theta and theta+180 are the same.
        angles = np.arange(n_gabors) * 180 / n_gabors
        total = round(seconds / ifi)
        frames = 0
        vbl = t0 = float('nan')
        phase_log = np.full(total, np.nan)
        print(f'\n{n_gabors} Gabor(s), {tf:g} Hz drift, {freq:g} cycles/pixel, sigma {sigma:g}.')
        print(f'Grid {cols} x {rows}, patch half-size {half:.0f} px. Click to stop.')

        for k in range(total):
            _, _, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            frames = k + 1
            # Phase from the time the NEXT frame is expected to appear, so a dropped
            # frame makes the phase jump to where it should be rather than lag.
            t_next = pm.get_secs() + ifi if math.isnan(vbl) else vbl + ifi
            if math.isnan(t0):
                t0 = t_next
            phase = (360 * tf * (t_next - t0)) % 360
            phase_log[k] = phase
            # No background fill: the frame is already cleared to mid-grey.
            for g in range(n_gabors):
                box = [cxs[g] - half, cys[g] - half, cxs[g] + half, cys[g] + half]
                pm.draw_gabor(w, 255, box, sigma, freq, angles[g], phase)
            vbl = pm.flip(w)[0]
        d = pm.diagnostic(w)
    finally:
        pm.close(w)
        pm.show_cursor()

    warmup = min(120, round(frames / 3))
    st_all = pm.frame_stats(d, ifi)
    st = pm.frame_stats(d, ifi, warmup)
    phases = phase_log[:frames]
    # Median step per frame should equal 360*tf*ifi; a wide spread means the
    # timestamps, not the loop, are what is jittering.
    d_phase = np.diff(np.degrees(np.unwrap(np.radians(phases))))
    report = dict(ifi=ifi, frames=frames, nGabors=n_gabors, temporalHz=tf, spatialFreq=freq, sigma=sigma,
                  halfSize=half, cols=cols, rows=rows, orientations=angles, achievedHz=st['achievedHz'],
                  skipped=st['skipped'], achievedHzWithSettling=st_all['achievedHz'],
                  cyclesAcrossPatch=2 * half * freq, phaseLog=phases,
                  phaseStepMedianDeg=float(np.median(d_phase)) if d_phase.size else float('nan'),
                  phaseStepExpectedDeg=360 * tf * ifi, summary=d['summary'])
    print('\n===== drifting Gabors, computed in the shader =====')
    print(f"Patches {n_gabors}; frames {frames}; skipped {report['skipped']}")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s")
    print(f"       {st_all['achievedHz']:.3f}/s if the first {warmup} settling frames are kept "
          f"(skipped {st_all['skipped']})")
    print(f"Carrier: {report['cyclesAcrossPatch']:.1f} cycles across a patch {2 * half:.0f} px wide")
    print(f"Phase step: {report['phaseStepMedianDeg']:.3f} deg/frame measured, "
          f"{report['phaseStepExpectedDeg']:.3f} expected")
    print('Every patch is one instance in a single draw call, and the drift is\n'
          'one float per patch per frame. Nothing was uploaded: run this again with\n'
          f'{min(200, 4 * n_gabors)} patches and the rate should barely move until fill rate, or in\n'
          "Python each call's argument handling, becomes the limit.")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('n_gabors', nargs='?', type=int, default=12)
    parser.add_argument('tf', nargs='?', type=float, default=2)
    parser.add_argument('freq', nargs='?', type=float, default=0.02)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(gabor_demo, args.seconds, args.n_gabors, args.tf, args.freq, threaded=args.threaded)


if __name__ == '__main__':
    main()
