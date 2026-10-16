#!/usr/bin/env python3
"""Probe: does Flip(w, when) ever show a frame before `when`?

    python3 probes/flip_when_v1.py              # about a minute
    python3 probes/flip_when_v1.py --record     # the same while recording a movie (scale 0.25)

For each delay (1 to 60 refreshes after the next refresh) and each point within the
refresh (0, 0.25, 0.5, 0.75 of a period after a refresh), several times: flip
once to get a refresh time, ask for the next frame at that time plus the delay,
and read the display's own report of when it was shown. Escape, Control-C or
Command-period ends it early, with what was measured so far. The frame should appear
at the first refresh at or after `when`. Prints, for each case, how many
refreshes early (negative) or late (positive) the display showed it, and saves
every trial to flip_when_v1.csv.

SPDX-License-Identifier: MIT
"""
import argparse
import csv
import math
import os
import sys
import tempfile

import numpy as np

# The PsychMetal release to probe: PM_VERSION=0.10.0 for another. Not part of a release.
VERSION = os.environ.get('PM_VERSION', '0.10.1')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402

DELAYS = [1, 2, 3, 5, 10, 14, 15, 16, 20, 30, 45, 60]
PHASES = [0.0, 0.25, 0.5, 0.75]


def presented_time(w, wait=0.25):
    """The display's report for the last frame: its presented time, or NaN."""
    pm.wait_secs(wait)
    row = np.asarray(pm.recent_frames(w, 1))[-1]
    return float(row[2]) if row[1] == 0 and row[2] > 0 else float('nan')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--record', action='store_true', help='record a movie at the same time (scale 0.25)')
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    w, rect, ifi = pm.open_window(None, 0)
    rows = []
    try:
        for _ in range(120):                 # settle the refresh grid
            pm.flip(w)
        period = pm.get_flip_interval(w)
        movie = os.path.join(tempfile.gettempdir(), 'flip_when_v1.mov')
        if args.record:
            pm.start_movie_recording(w, movie, scale=0.25, sound=False)
        escape = pm.kb_name('ESCAPE')
        stopped = False
        for delay in DELAYS:
            for phase in PHASES:
                for rep in range(args.repeats):
                    if stopped or pm.kb_check()[2][escape]:
                        stopped = True
                        break
                    pm.fill_rect(w, 0)
                    pm.flip(w)
                    base = presented_time(w, 0.05)           # the last frame, as the display saw it
                    if not math.isfinite(base):
                        continue
                    # Counted from the next refresh after now: the report took a few refreshes to come.
                    elapsed = math.ceil((pm.get_secs() - base) / period)
                    when = base + (elapsed + delay + phase) * period
                    pm.fill_rect(w, 255 if rep % 2 else 128)
                    returned = pm.flip(w, when)[0]
                    shown = presented_time(w)
                    expected = base + math.ceil(elapsed + delay + phase - 1e-6) * period
                    rows.append(dict(delay=delay, phase=phase, rep=rep, base=base, when=when, returned=returned,
                                     shown=shown, expected=expected,
                                     error=round((shown - expected) / period) if math.isfinite(shown) else float('nan'),
                                     returnedError=round((returned - expected) / period)))
        if args.record:
            r = pm.stop_movie_recording(w)
            print(f"Recorded {r['frames']:.0f} frames ({r['late']:.0f} late) while probing.")
    finally:
        pm.close(w)
    path = 'flip_when_v1.csv'
    with open(path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f'\nFlip(w, when): refreshes from the first refresh at or after `when` to when the display showed the frame')
    print('(0 is right; negative is shown before `when`; each cell lists every repeat). Period %.4f ms.\n' % (1000 * period))
    print('delay  ' + ''.join(f'phase {p:<8}' for p in PHASES))
    early = late = 0
    for delay in DELAYS:
        cells = []
        for phase in PHASES:
            errors = [r['error'] for r in rows if r['delay'] == delay and r['phase'] == phase]
            early += sum(1 for e in errors if e < 0)
            late += sum(1 for e in errors if e > 0)
            cells.append(','.join('?' if not math.isfinite(e) else f'{e:+d}' for e in errors))
        print(f'{delay:>5}  ' + ''.join(f'{c:<14}' for c in cells))
    returned_off = sum(1 for r in rows if math.isfinite(r['shown']) and r['returnedError'] != r['error'])
    print(f'\n{len(rows)} trials: {early} shown early, {late} shown late; Flip returned a time other than the '
          f'display\'s for {returned_off}. Saved to {path}.')


if __name__ == '__main__':
    main()
