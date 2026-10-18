#!/usr/bin/env python3
"""Probe: frames record_demo's display never shows, over repeated runs.

    python3 probes/record_unreported_v4.py          # 5 runs, live clock
    python3 probes/record_unreported_v4.py 10       # 10 runs

v2 found the last frame of a recording dropped (status 1) although ready in time, and
in one run of two the paused frame dropped. v3 runs record_demo quietly several
times and, for every frame not shown, prints when the frames around it were
committed, asked for, finished on the GPU and shown, in refreshes from its own
projected refresh. v4 finds the pause as the longest gap between frames shown, for the 0.11.0
record_demo, which pauses on its first click (frame 60 at 60 Hz) and resumes the
motion where it stopped, instead of at 1.5 s. A dropped frame whose GPU end is after 0 was not ready; one whose
GPU end is before 0 was ready and was replaced anyway. Uses the 0.11.0 package by
default (PM_VERSION).

SPDX-License-Identifier: MIT
"""
import contextlib
import io
import os
import sys

import numpy as np

VERSION = os.environ.get('PM_VERSION', '0.11.0')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402
import record_demo  # noqa: E402

RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
kept = {}
stop = pm.stop_movie_recording


def stop_and_keep(w):
    result = stop(w)
    pm.wait_secs(.3)
    kept['ifi'] = pm.get_flip_interval(w)
    kept['diag'] = pm.diagnostic(w)
    kept['rec'] = result
    return result


pm.stop_movie_recording = stop_and_keep
print(f'PsychMetal {pm.version()}: {RUNS} runs of record_demo (live clock, ProRes 4444, full size).')
print('Status: 0 shown, 1 dropped by the system, 2 no report, 3 GPU error, 4 no drawable.')
cols = ('projectedTimestamp', 'presentRequestedTime', 'committedTime', 'gpuEndTime', 'actualTimestamp')
for run in range(RUNS):
    with contextlib.redirect_stdout(io.StringIO()):
        out = pm.run(record_demo.record_demo, 'psychmetal_recording.mov', 'prores4444', 3.0, 1.0, 'live')
    n, ifi, d, rec = int(out['frames']), kept['ifi'], kept['diag'], kept['rec']
    first = len(d['flipNumber']) - n
    status = d['actualStatus'][first:].astype(int)
    shown = np.where(status == 0, d['actualTimestamp'][first:], np.nan)
    gaps = np.round(np.diff(shown) / ifi)
    pause = int(np.nanargmax(gaps)) + 1        # frame `pause` waited half a second
    long = [k for k in np.flatnonzero(gaps > 1) if k != pause - 1]
    bad = np.flatnonzero(status != 0)
    print(f'\nrun {run + 1}: {n} frames, {rec["late"]:.0f} late, {rec["unreported"]:.0f} unreported by the recorder; '
          f'pause {pause - 1}->{pause}: {gaps[pause - 1]:.0f} refreshes; not shown: '
          + (', '.join(f'{k} (status {status[k]})' for k in bad) or 'none')
          + '; other gaps over a refresh: ' + (', '.join(f'{k}->{k + 1} {gaps[k]:.0f}' for k in long) or 'none'))
    for k in bad:
        zero = d['projectedTimestamp'][first + k]
        print('     frame status  projected      asked  committed    GPU end      shown')
        for j in range(max(0, k - 2), min(n, k + 3)):
            i = first + j
            vals = ''.join(f'{(d[c][i] - zero) / ifi:>11.2f}' if np.isfinite(d[c][i]) and d[c][i] > 0 else f'{"-":>11}'
                           for c in cols)
            print(f'    {j:>5} {status[j]:>6}{vals}')
