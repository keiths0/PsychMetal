#!/usr/bin/env python3
"""Probe: what makes Flip(w, when) show a frame a refresh early?

    python3 probes/flip_when_v2.py              # about two minutes

record_demo shows its paused frame, asked for half a second after the frame
before it, a refresh early, every time; flip_when_v1 never saw a frame early.
They differ in three ways, and this tries each combination:

  start   the time asked for counts from the time flip returned, in a run of
          frames flipped one after another (as the demo does), or from the
          display's report of a frame after a pause (as v1 does);
  load    what each frame draws: a rectangle, or a Gabor patch and text over
          the whole display (as the demo does);
  record  no recording, a recording at a quarter of the size, or at full size.

Each trial: 30 frames flipped one after another, then one asked for half a
second (30 refreshes at 60 Hz) after the start. The display's own reports give
how many refreshes after the frame before it the asked-for frame appeared: it
should be the number asked for. Escape, Control-C or Command-period ends it
early. Saves every trial to flip_when_v2.csv.

SPDX-License-Identifier: MIT
"""
import csv
import itertools
import math
import os
import sys
import tempfile

import numpy as np

# The PsychMetal release to probe: PM_VERSION=0.10.0 for another. Not part of a release.
VERSION = os.environ.get('PM_VERSION', '0.10.1')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402

TRIALS = 6


def reports(w, n):
    """The display's reports of the last n frames: presented times, NaN where not shown."""
    pm.wait_secs(.25)
    rows = np.asarray(pm.recent_frames(w, n))
    return np.where((rows[:, 1] == 0) & (rows[:, 2] > 0), rows[:, 2], np.nan)


def main():
    w, rect, ifi = pm.open_window(None, 128)
    W, H = rect[2], rect[3]
    r = min(W, H) * .2
    escape = pm.kb_name('ESCAPE')
    rows = []
    try:
        for _ in range(120):
            pm.flip(w)
        period = pm.get_flip_interval(w)
        delay = round(.5 / period)              # refreshes in half a second
        for start, load, record in itertools.product(['returned', 'reported'], ['light', 'heavy'], [0, .25, 1]):
            movie = os.path.join(tempfile.gettempdir(), 'flip_when_v2.mov')
            if record:
                pm.start_movie_recording(w, movie, scale=record, sound=False)
            for trial in range(TRIALS):
                if pm.kb_check()[2][escape]:
                    raise KeyboardInterrupt
                vbl = 0.0
                for k in range(30):
                    pm.fill_rect(w, 128)
                    if load == 'heavy':
                        pm.draw_gabor(w, None, [W / 2 - r, H / 2 - r, W / 2 + r, H / 2 + r], .5, 6 / r, 0, 12 * k)
                        pm.draw_text(w, f'frame {k}', W * .05, H * .05, 255, max(14, H * .04))
                    vbl = pm.flip(w)[0]
                if start == 'reported':
                    base = reports(w, 1)[-1]        # the last frame, as the display saw it, after a pause
                else:
                    base = vbl                      # as flip returned it, at once
                pm.fill_rect(w, 255)
                returned = pm.flip(w, base + delay * period)[0]
                shown = reports(w, 2)               # the frame before, and the one asked for
                gap = (shown[1] - shown[0]) / period
                ahead = (shown[1] - (base + delay * period)) / period
                rows.append(dict(start=start, load=load, record=record, trial=trial, base=base,
                                 returned=returned, before=shown[0], shown=shown[1], gap=gap, ahead=ahead,
                                 returnedAhead=(returned - (base + delay * period)) / period))
            if record:
                rec = pm.stop_movie_recording(w)
                rows[-1]['note'] = f"{rec['late']:.0f} late while recording"
    except KeyboardInterrupt:
        print('Stopped early.')
    finally:
        try:
            pm.stop_movie_recording(w)
        except Exception:
            pass
        pm.close(w)
    if not rows:
        return
    path = 'flip_when_v2.csv'
    fields = sorted({k for row in rows for k in row}, key=lambda k: list(rows[0]).index(k) if k in rows[0] else 99)
    with open(path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f'\nA frame asked for {delay} refreshes after the start: when the display showed it, in refreshes from the')
    print("time asked for (0 is right, negative is early), one number per trial.\n")
    print(f"{'start':<10}{'load':<7}{'record':<8}shown relative to the time asked for")
    for start, load, record in itertools.product(['returned', 'reported'], ['light', 'heavy'], [0, .25, 1]):
        cell = [x for x in rows if x['start'] == start and x['load'] == load and x['record'] == record]
        if not cell:
            continue
        values = ' '.join('  ?' if not math.isfinite(x['ahead']) else f"{round(x['ahead']):+3d}" for x in cell)
        early = sum(1 for x in cell if math.isfinite(x['ahead']) and round(x['ahead']) < 0)
        print(f"{start:<10}{load:<7}{('none' if not record else str(record)):<8}{values}" + (f'   {early} early' if early else ''))
    print(f'\nSaved to {path}.')


if __name__ == '__main__':
    main()
