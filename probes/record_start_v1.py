#!/usr/bin/env python3
"""Probe: why the first frames of a recording come late.

    python3 probes/record_start_v1.py          # 3 runs
    python3 probes/record_start_v1.py 5

record_demo, live clock, ProRes 4444 at full size, shows its frame 2 a refresh late
in most runs: the first frames after start_movie_recording. For the first eight
frames of each run, and any other frame shown late, this prints where the time
went: waiting for a drawable, encoding (drawing and the recorder's copy, on the
CPU), the GPU pass, and when the frame was committed and shown against the
refresh it was aimed at. Uses the 0.11.0 package by default (PM_VERSION).

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

RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
kept = {}
stop = pm.stop_movie_recording


def stop_and_keep(w):
    result = stop(w)
    pm.wait_secs(.3)
    kept['ifi'] = pm.get_flip_interval(w)
    kept['diag'] = pm.diagnostic(w)
    return result


pm.stop_movie_recording = stop_and_keep
print(f'PsychMetal {pm.version()}: {RUNS} runs of record_demo (live clock, ProRes 4444, full size).')
print('Times in ms. "committed" and "shown" are refreshes after the refresh the frame was aimed at;')
print('a frame is late when shown is 1 or more.')
for run in range(RUNS):
    with contextlib.redirect_stdout(io.StringIO()):
        out = pm.run(record_demo.record_demo, 'psychmetal_recording.mov', 'prores4444', 3.0, 1.0, 'live')
    n, ifi, d = int(out['frames']), kept['ifi'], kept['diag']
    first = len(d['flipNumber']) - n
    proj = d['projectedTimestamp'][first:]
    shown = np.where(d['actualStatus'][first:] == 0, d['actualTimestamp'][first:], np.nan)
    late = (shown - proj) / ifi
    rows = sorted(set(range(min(8, n))) | set(np.flatnonzero(np.round(late) >= 1).tolist()))
    print(f'\nrun {run + 1}: {n} frames, late: {[int(k) for k in np.flatnonzero(np.round(late) >= 1)]}')
    print('  frame  drawable wait  encode   GPU pass  committed  shown')
    for k in rows:
        i = first + k
        print(f'  {k:>5}  {d["drawableWaitMs"][i]:>13.2f} {d["encodeMs"][i]:>7.2f} {d["gpuPassMs"][i]:>10.2f}'
              f' {(d["committedTime"][i] - proj[k]) / ifi:>10.2f} {late[k]:>6.2f}')
