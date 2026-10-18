#!/usr/bin/env python3
"""Probe: which frame of record_demo the display never reports, and what became of it.

    python3 probes/record_unreported_v2.py            # live clock, as record_demo --clock live
    python3 probes/record_unreported_v2.py virtual    # the demo's default clock

record_demo reports one frame fewer than it flipped (150 of 151), with or without the
pause fix in 0.11.0. This runs the demo unchanged, keeps the display's records of its
frames before the window closes, and lists every frame not shown (status 0), with the
gaps to the frames either side. v2 adds, for the frames around each one not shown, when
each was committed, when the system was asked to show it, when its GPU work ended and
when it was shown, so a frame replaced because its GPU work was late can be told from
one replaced while ready. Uses the 0.11.0 package by default (PM_VERSION).

SPDX-License-Identifier: MIT
"""
import os
import sys

import numpy as np

VERSION = os.environ.get('PM_VERSION', '0.11.0')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402
import record_demo  # noqa: E402

clock = sys.argv[1] if len(sys.argv) > 1 else 'live'
kept = {}
stop = pm.stop_movie_recording


def stop_and_keep(w):
    result = stop(w)
    pm.wait_secs(.3)
    kept['rows'] = np.asarray(pm.recent_frames(w, 256))
    kept['ifi'] = pm.get_flip_interval(w)
    kept['diag'] = pm.diagnostic(w)
    return result


pm.stop_movie_recording = stop_and_keep
out = pm.run(record_demo.record_demo, 'psychmetal_recording.mov', 'prores4444', 3.0, 1.0, clock)
n = int(out['frames'])
rows, ifi = kept['rows'][-n:], kept['ifi']
status = rows[:, 1].astype(int)
shown = np.where((status == 0) & (rows[:, 2] > 0), rows[:, 2], np.nan)
pause = int(round(1.5 / ifi))
print(f'\n{n} frames flipped while recording ({clock} clock); frame {pause} was the one given a time'
      f' half a second ahead, so frame {pause + 1} came right after the pause.')
print('Status: 0 shown, 1 dropped by the system (replaced before it was shown), 2 no report, 3 GPU error, 4 no drawable.')
bad = np.flatnonzero(status != 0)
if not len(bad):
    print('Every frame was reported shown.')
for k in bad:
    gap = next(((shown[j] - shown[k - 1]) / ifi for j in range(k + 1, n) if k > 0 and np.isfinite(shown[j])), np.nan)
    print(f'  frame {k}: status {status[k]}; frame {k - 1} to the next frame shown: {gap:.2f} refreshes'
          f' (frames {k - 1} and {k + 1} {"both shown" if k > 0 and k + 1 < n and np.isfinite(shown[k - 1]) and np.isfinite(shown[k + 1]) else "not both shown"})')
late = np.flatnonzero(np.round(np.diff(shown) / ifi) > 1)
print('Gaps of more than a refresh between frames shown, other than the pause: ' +
      (', '.join(f'frames {k} to {k + 1}: {np.diff(shown)[k] / ifi:.2f}' for k in late if k != pause) or 'none'))

d = kept['diag']
m = len(d['flipNumber'])
cols = [('projected', d['projectedTimestamp']), ('asked', d['presentRequestedTime']), ('committed', d['committedTime']),
        ('GPU end', d['gpuEndTime']), ('shown', d['actualTimestamp'])]
first = m - n                                   # the diagnostic rows of the recording's frames
print('\nAround each frame not shown: refreshes from that frame\'s projected refresh ("-" none).')
for k in bad:
    zero = d['projectedTimestamp'][first + k]
    print(f'  frame {k}:')
    print('    frame  status ' + ''.join(f'{name:>11}' for name, _ in cols))
    for j in range(max(0, k - 2), min(n, k + 3)):
        i = first + j
        vals = ''.join(f'{(c[i] - zero) / ifi:>11.2f}' if np.isfinite(c[i]) and c[i] > 0 else f'{"-":>11}' for _, c in cols)
        print(f'    {j:>5}  {int(d["actualStatus"][i]):>6} {vals}')
