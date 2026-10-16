#!/usr/bin/env python3
"""Probe: a Flip for the next refresh just after a Flip with a time far ahead.

    python3 probes/flip_when_v3.py              # delays 2, 5, 15, 20, 30, 60: about 40 seconds
    python3 probes/flip_when_v3.py 14 15 16 17 20 30   # chosen delays

record_demo's paused frame was never shown: the program flipped it with a time
half a second ahead (flip returns long before that), then at once flipped the
next frame for "the next refresh", and the system showed that one as soon as it
could, over the frame still waiting. Each trial here does the same: 30 frames
flipped one after another, one asked for `delay` refreshes later, and the next
flipped at once with no time. From the display's reports: was the waiting frame
shown, at its time, and the next one a refresh after it?

Escape, Control-C or Command-period ends it early.

SPDX-License-Identifier: MIT
"""
import math
import os
import sys

import numpy as np

# The PsychMetal release to probe: PM_VERSION=0.10.0 for another. Not part of a release.
VERSION = os.environ.get('PM_VERSION', '0.10.1')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402

DELAYS = [int(d) for d in sys.argv[1:]] or [2, 5, 15, 20, 30, 60]
FOLLOWING = 5


def main():
    w, rect, ifi = pm.open_window(None, 128)
    escape = pm.kb_name('ESCAPE')
    results = []
    statuses = []
    try:
        for _ in range(120):
            pm.flip(w)
        period = pm.get_flip_interval(w)
        for delay in DELAYS:
            for trial in range(5):
                if pm.kb_check()[2][escape]:
                    raise KeyboardInterrupt
                vbl = 0.0
                for k in range(30):
                    pm.fill_rect(w, 128)
                    vbl = pm.flip(w)[0]
                pm.fill_rect(w, 255)
                waiting = pm.flip(w, vbl + delay * period)[0]   # waits for its time; flip returns at once
                following = []
                for k in range(FOLLOWING):                # then a run of frames, each for the next refresh
                    pm.fill_rect(w, 0 if k % 2 == 0 else 64)
                    following.append(pm.flip(w)[0])
                pm.wait_secs(.3)
                rows = np.asarray(pm.recent_frames(w, 2 + FOLLOWING))   # the last of the run, the waiting one, the rest
                shown = np.where((rows[:, 1] == 0) & (rows[:, 2] > 0), rows[:, 2], np.nan)
                statuses.append([int(s) for s in rows[:, 1]])
                waited = (shown[1] - shown[0]) / period
                after = np.diff(shown[1:]) / period       # waiting -> first, first -> second, ...
                # Where the engine aimed each, against where the display showed it (refreshes).
                aims = [(waiting - shown[1]) / period] + [(f - x) / period for f, x in zip(following, shown[2:])]
                results.append((delay, waited, after, aims))
    except KeyboardInterrupt:
        print('Stopped early.')
    finally:
        pm.close(w)
    print(f'\nA frame asked for `delay` refreshes after the one before it, then {FOLLOWING} flipped at once, each for')
    print('the next refresh. For each trial: refreshes until the waiting frame was shown (should be delay), then')
    print("between each of the following frames (each should be 1). '?' is a frame the display never showed.\n")
    bad = 0
    fmt = lambda x: '?' if not math.isfinite(x) else f'{x:.0f}'
    for delay in sorted({r[0] for r in results}):
        cells = [(a, b) for d, a, b, _ in results if d == delay]
        print(f'delay {delay:>3}:  ' + '  '.join(fmt(a) + '/' + ','.join(fmt(x) for x in b) for a, b in cells))
        bad += sum(1 for a, b in cells if not (math.isfinite(a) and round(a) == delay and
                                              all(math.isfinite(x) and round(x) == 1 for x in b)))
        aims = [m for d, _, _, m in results if d == delay]
        print('            engine aim minus display: ' +
              '  '.join(','.join('?' if not math.isfinite(x) else f'{x:+.0f}' for x in m) for m in aims))
    odd = [s for s in statuses if any(x != 0 for x in s)]
    if odd:
        print('\nStatus of each frame (last of the run, waiting, following), where any was not 0;')
        print('0 shown, 1 dropped by the system (replaced before it was shown), 2 no report yet:')
        for s in odd:
            print('    ' + ' '.join(str(x) for x in s))
    print(f'\n{len(results)} trials, {bad} wrong. PM_HOLD_LIMIT={os.environ.get("PM_HOLD_LIMIT", "15 (default)")}')


if __name__ == '__main__':
    main()
