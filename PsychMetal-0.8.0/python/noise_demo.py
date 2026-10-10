#!/usr/bin/env python3
"""Full-screen dynamic white noise, nothing uploaded.

Python port of PsychMetalNoiseDemo.m:

    python3 noise_demo.py                          # 20 s, cycles all four modes
    python3 noise_demo.py 20 uniform mono
    python3 noise_demo.py 20 normal colour 38

Click any mouse button to stop. A new independent value for every pixel on
every frame, at the full panel resolution. With no mode it spends a quarter of
the run in each combination of uniform/normal and mono/colour.

A pixel's value is a hash of its position and the frame's seed, evaluated in
the fragment shader, so each frame costs one instanced quad and four bytes of
transfer, where generating it on the CPU would take up to three refreshes and
upload tens of megabytes. The rate should be the display's, with zero skips,
in every mode.

It is still reproducible: every frame's seed is recorded, and at the end one
frame is rebuilt from its seed alone with noise_values and checked for
determinism. Storing the seeds instead of the frames is what makes reverse
correlation with this noise practical.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def noise_demo(seconds=20, dist=None, chroma=None, spread=128):
    # No mode means cycle: the point of the demo is that all four cost the same.
    cycling = dist is None and chroma is None
    if cycling:
        modes = [('uniform', 'mono'), ('normal', 'mono'), ('uniform', 'colour'), ('normal', 'colour')]
    else:
        modes = [(dist or 'uniform', chroma or 'mono')]
    # Mid-grey background: never visible here, since the noise covers the window.
    w, rect, ifi = pm.open_window(None, 128)
    try:
        pm.hide_cursor()
        total = round(seconds / ifi)
        n_mode = len(modes)
        per_mode = max(1, total // n_mode)
        seeds = np.full(total, -1, dtype=np.int64)
        mode_of = np.full(total, -1)
        frames = 0
        last_label = ''
        print(f'\nFull-screen dynamic noise, {rect[2]:.0f} x {rect[3]:.0f}, spread {spread:g}.')
        if cycling:
            print(f'Cycling uniform/normal x mono/colour, {per_mode * ifi:.1f} s each.')
        else:
            print(f'{modes[0][0]}, {modes[0][1]}.')
        print('Click to stop.\n')

        for k in range(total):
            _, _, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            frames = k + 1
            m = min(n_mode - 1, k // per_mode)
            mode_of[k] = m
            label = f'{modes[m][0]}, {modes[m][1]}'
            if label != last_label:
                print(f'  {label}')
                last_label = label
            # Seed omitted, so one is drawn and handed back. Recording it is the
            # whole reproducibility story: four bytes instead of the frame.
            seeds[k] = pm.draw_noise(w, rect, None, modes[m][0], modes[m][1], None, spread)
            pm.flip(w)
        d = pm.diagnostic(w)

        # Rebuild one frame from its seed alone, well after it was shown. CPU
        # work, deliberately outside the loop, which is the point being made.
        pick = max(1, round(frames * 0.5)) - 1
        dist_p, chroma_p = modes[mode_of[pick]]
        t0 = pm.get_secs()
        rebuilt = pm.noise_values(w, rect, int(seeds[pick]), dist_p, chroma_p, None, spread)
        rebuild_ms = (pm.get_secs() - t0) * 1000
        # Determinism is a property of the hash, not the size, so it is checked
        # on a corner rather than a second full-screen array.
        corner = [0, 0, 256, 256]
        stable = np.array_equal(pm.noise_values(w, corner, int(seeds[pick]), dist_p, chroma_p, None, spread),
                                pm.noise_values(w, corner, int(seeds[pick]), dist_p, chroma_p, None, spread))
    finally:
        pm.close(w)
        pm.show_cursor()

    warmup = min(120, round(frames / 3))
    st_all = pm.frame_stats(d, ifi)
    st = pm.frame_stats(d, ifi, warmup)
    seed_bytes = frames * 8
    frame_bytes = frames * rebuilt.size * 8
    report = dict(ifi=ifi, frames=frames, seeds=seeds[:frames], modeOf=mode_of[:frames], modes=modes,
                  spread=spread, achievedHz=st['achievedHz'], skipped=st['skipped'],
                  achievedHzWithSettling=st_all['achievedHz'], rebuiltFrame=pick + 1, rebuildMs=rebuild_ms,
                  rebuildStable=stable, rebuiltMin=float(rebuilt.min()), rebuiltMax=float(rebuilt.max()),
                  rebuiltMean=float(rebuilt.mean()), seedLogBytes=seed_bytes, frameLogBytes=frame_bytes,
                  summary=d['summary'])
    print('\n===== dynamic white noise, computed in the shader =====')
    print(f"Frames {frames}; skipped {report['skipped']}")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s")
    print(f"       {st_all['achievedHz']:.3f}/s if the first {warmup} settling frames are kept "
          f"(skipped {st_all['skipped']})")
    if cycling:
        print('\nPer mode:')
        for m in range(n_mode):
            rows = np.flatnonzero(mode_of[:frames] == m)
            if rows.size < 5:
                continue
            sub = pm.frame_stats(d, ifi, rows[0] + 6)
            print(f"  {modes[m][0] + ', ' + modes[m][1]:<18} {sub['achievedHz']:8.3f}/s")
        print("  (each runs from that mode's start to the end of the run, so a row\n"
              '   includes the modes after it; read them as "no mode broke the rate")')
    print(f'\nRECONSTRUCTION. Frame {pick + 1} rebuilt from seed {seeds[pick]} alone, {rebuild_ms:.1f} ms.')
    print(f"  repeatable: {'yes' if stable else 'NO - the generator is not deterministic'}")
    print(f"  range {report['rebuiltMin']:.4f} to {report['rebuiltMax']:.4f}, mean {report['rebuiltMean']:.4f}")
    print(f'  {rebuild_ms:.1f} ms is why this is not done per frame, and {rebuild_ms:.1f} ms x {frames} frames')
    print('  is why the CPU cannot generate this stimulus in the first place.')
    print(f'\nSTORAGE. Seed log {seed_bytes / 1e3:.1f} kB against {frame_bytes / 1e6:.1f} MB for the frames '
          'themselves,')
    print(f'  a factor of {frame_bytes / max(1, seed_bytes):.0f}, and the frames are recoverable from the seeds.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('dist', nargs='?', choices=['uniform', 'normal'], default=None)
    parser.add_argument('chroma', nargs='?', choices=['mono', 'colour', 'color'], default=None)
    parser.add_argument('spread', nargs='?', type=float, default=128)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(noise_demo, args.seconds, args.dist, args.chroma, args.spread, threaded=args.threaded)


if __name__ == '__main__':
    main()
