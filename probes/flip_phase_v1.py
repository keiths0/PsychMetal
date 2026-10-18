#!/usr/bin/env python3
"""Probe: how late in a refresh a Flip for the next refresh can be committed and still make it.

    python3 probes/flip_phase_v1.py            # without and then with a movie being recorded
    python3 probes/flip_phase_v1.py plain      # without only

The engine projects a Flip with no time for the first refresh at least a whole refresh after
the frame is committed. While a movie is recorded at 6K, frames committed only 1.0 to 1.2
refreshes before that refresh were shown one later, and those committed 1.4 or more before
it were shown on time (probes/record_start_v1.py). This measures the edge: each trial waits
until a chosen fraction of a refresh after a frame was shown, then flips, and reads from the
display's reports how many refreshes after that frame the new one was shown, and when it was
committed. Uses the 0.11.0 package by default (PM_VERSION).

Escape, Control-C or Command-period ends it early.

SPDX-License-Identifier: MIT
"""
import os
import sys
import tempfile

import numpy as np

VERSION = os.environ.get('PM_VERSION', '0.11.0')
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PsychMetal-' + VERSION, 'python'))
import psychmetal as pm  # noqa: E402

PHASES = np.round(np.arange(0.0, 1.0, 0.1), 2)
TRIALS = 8
modes = ['plain'] if sys.argv[1:] == ['plain'] else ['plain', 'recording']


def measure(w, ifi, recording):
    rows = []
    path = os.path.join(tempfile.gettempdir(), 'flip_phase_v1.mov')
    if recording:
        pm.start_movie_recording(w, path, 'prores4444', 1, sound=False, clock='live')
    try:
        for _ in range(30):
            pm.flip(w)
        for phase in PHASES:
            for trial in range(TRIALS):
                pm.fill_rect(w, 100)
                pm.flip(w)
                pm.wait_secs(4 * ifi)                       # the frame is shown and reported
                anchor = pm.recent_frames(w, 1)[0]
                shown_at = anchor[2]
                k = np.ceil((pm.get_secs() - shown_at) / ifi)  # the next refresh from now
                pm.wait_secs('UntilTime', shown_at + (k + phase) * ifi)
                pm.fill_rect(w, 140 + 10 * trial)
                pm.flip(w)
                pm.wait_secs(5 * ifi)
                d = pm.diagnostic(w)
                committed = d['committedTime'][-1]
                shown = d['actualTimestamp'][-1] if d['actualStatus'][-1] == 0 else np.nan
                # Refreshes from the last refresh before the commit to the one that showed it.
                base = shown_at + np.floor((committed - shown_at) / ifi) * ifi
                rows.append((phase, (committed - base) / ifi, (shown - base) / ifi))
    finally:
        if recording:
            pm.stop_movie_recording(w)
            os.remove(path) if os.path.exists(path) else None
    return np.array(rows)


def main():
    w, rect, ifi = pm.open_window(None, 128)
    results = {}
    try:
        ifi = pm.get_flip_interval(w)
        for mode in modes:
            if pm.kb_check()[2][pm.kb_name('ESCAPE')]:
                break
            results[mode] = measure(w, ifi, mode == 'recording')
    finally:
        pm.close(w)
    print(f'\nPsychMetal {pm.version()}. A frame was committed at the phase shown (fraction of a refresh after')
    print('the last refresh); "shown" is how many refreshes after that refresh the display showed it.')
    print('The engine says 2, the refresh after the next; 3 is a refresh later than flip returned.')
    for mode, r in results.items():
        print(f'\n{mode}:')
        print('  asked   committed at (median)   shown after: refreshes, count')
        for phase in PHASES:
            sel = r[r[:, 0] == phase]
            shown = sel[:, 2]
            counts = {int(k): int(v) for k, v in zip(*np.unique(np.round(shown[np.isfinite(shown)]), return_counts=True))}
            missing = int(np.sum(~np.isfinite(shown)))
            print(f'  {phase:4.1f}   {np.median(sel[:, 1]):6.2f}                   '
                  + ', '.join(f'{k}: {v}' for k, v in sorted(counts.items()))
                  + (f', not shown: {missing}' if missing else ''))


if __name__ == '__main__':
    main()
