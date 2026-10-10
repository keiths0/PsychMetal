#!/usr/bin/env python3
"""Compare a preloaded reference (left) with update_texture (right).

Python port of PsychMetalMotionTest.m:

    python3 motion_test.py             # 1024 x 1024, 600 measured frames
    python3 motion_test.py 2048
    python3 motion_test.py 2048 1200

Both panels must move RIGHT together, with matching phase, orientation and
brightness. The 32 frames are precomputed as float32 before the window opens,
so nothing is generated in the loop: the right panel re-uploads one texture
every frame from them, the left draws 32 textures made in advance. Static
markers in two corners expose flips and transposes. Escape aborts.

The first 120 frames are warm-up. Saves PsychMetalMotion-<time>.txt and .json
in the current folder.

SPDX-License-Identifier: MIT
"""
import argparse
import json
import math
import sys
import time

import numpy as np

import psychmetal as pm


def to_json(o):
    if isinstance(o, np.ndarray):
        return [None if isinstance(v, float) and not np.isfinite(v) else v for v in o.tolist()] if o.ndim == 1 \
            else o.tolist()
    if isinstance(o, (np.generic,)):
        return o.item()
    return str(o)


def motion_test(n=1024, frames=600):
    if not (n == int(n) and 64 <= n <= 2048):
        raise ValueError('n must be 64..2048')
    if not (frames == int(frames) and 60 <= frames <= 12000):
        raise ValueError('frames must be 60..12000')
    n, frames = int(n), int(frames)
    base = time.strftime('PsychMetalMotion-%Y%m%d-%H%M%S')
    report = dict(size=n, frames=frames, host=f'Python {sys.version.split()[0]}', native=pm._core.__file__,
                  error='', complete=False)
    print('Precomputing 32 frames. LEFT: preloaded reference. RIGHT: updated texture.')
    print('Both must move RIGHT together, with matching phase, orientation and brightness. Escape aborts.')
    x = np.arange(n, dtype=np.float32) / n
    images = []
    for j in range(32):
        row = (0.5 + 0.4 * np.cos(2 * np.pi * (3 * x - j / 32))).astype(np.float32)
        img = np.tile(row, (n, 1))
        # Static asymmetric markers expose flips and transposes.
        tall, wide = math.ceil(n / 12), math.ceil(n / 6)
        img[:tall, :wide] = 1
        img[n - tall:, n - wide:] = 0
        images.append(img)
    w = None
    try:
        w, r, ifi = pm.open_window()
        side = min(r[2] * .44, r[3] * .8)
        cy = r[3] / 2
        left = [r[2] * .25 - side / 2, cy - side / 2, r[2] * .25 + side / 2, cy + side / 2]
        right = [left[0] + r[2] * .5, left[1], left[2] + r[2] * .5, left[3]]
        refs = [pm.make_texture(w, im) for im in images]
        t = pm.make_texture(w, images[0])
        count = 120 + frames
        upload = np.zeros(count)
        missing = np.zeros(count, dtype=bool)
        escape = pm.kb_name('ESCAPE')
        for k in range(count):
            down, _, keys = pm.kb_check()
            if down and keys[escape]:
                raise RuntimeError('Aborted with Escape')
            j = k % 32
            began = time.perf_counter()
            pm.update_texture(w, t, images[j])
            upload[k] = (time.perf_counter() - began) * 1000
            pm.draw_texture(w, refs[j], None, left)
            pm.draw_texture(w, t, None, right)
            try:
                pm.flip(w)
            except pm.PsychMetalError as err:
                if 'Presentation callback returned no timestamp.' not in str(err):
                    raise
                missing[k] = True
        d = pm.diagnostic(w)
        pm.close(w)
        w = None
        stats = pm.frame_stats(d, ifi, 120)
        status, actual = d['actualStatus'], d['actualTimestamp']
        ts = actual[120:][np.isfinite(actual[120:]) & (status[120:] == 0)]
        hz = (ts.size - 1) / (ts[-1] - ts[0]) if ts.size > 1 and ts[-1] > ts[0] else float('nan')
        report.update(uploadMs=upload, missingAtFlip=missing, stats=stats, warmupMissing=int(np.sum(status[:120] == 1)),
                      measuredMissing=int(np.sum(status[120:] == 1)), deliveryHz=hz, complete=True,
                      history={k: v for k, v in d.items() if k not in ('summary', 'startup')}, summary=d['summary'])
        text = (f"Motion test {n}x{n}: delivery {hz:.3f} Hz; {stats['confirmed']}/{frames} confirmed; "
                f"{stats['skipped']} long adjacent intervals; missing warm-up/measured "
                f"{report['warmupMissing']}/{report['measuredMissing']}; median upload "
                f"{np.median(upload[120:]):.3f} ms.\n")
        print(f'{text}Saved {base}.txt and .json')
        with open(base + '.txt', 'w') as f:
            f.write(f"{text}Native: {report['native']}\nVisual match requires user confirmation.\n")
    except BaseException as err:
        if w is not None:
            try:
                pm.close(w)
            except Exception:
                pass
        report['error'] = str(err)
        raise
    finally:
        with open(base + '.json', 'w') as f:
            json.dump(report, f, default=to_json)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('n', nargs='?', type=int, default=1024)
    parser.add_argument('frames', nargs='?', type=int, default=600)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(motion_test, args.n, args.frames, threaded=args.threaded)


if __name__ == '__main__':
    main()
