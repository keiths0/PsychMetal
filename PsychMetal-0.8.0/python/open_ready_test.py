#!/usr/bin/env python3
"""Verify background confirmation and the first stimulus across repeated opens.

Python port of PsychMetalOpenReadyTest.m:

    python3 open_ready_test.py         # ten opens
    python3 open_ready_test.py 30

Each open must confirm two consecutive presentations of the requested
background before returning, keep those startup frames out of the stimulus
history, and then present the first stimulus: immediately on odd opens, and
at a deadline 0.25 s ahead on even ones, within the next refresh plus 2 ms.
Backgrounds alternate 0, 32 and 64. Software timing, not physical onset.

Saves PsychMetalOpenReady-<time>.txt and .json in the current folder. Escape
aborts between opens.

SPDX-License-Identifier: MIT
"""
import argparse
import json
import time

import numpy as np

import psychmetal as pm


def to_json(o):
    if isinstance(o, np.ndarray):
        return [None if isinstance(v, float) and not np.isfinite(v) else v for v in o.tolist()] if o.ndim == 1 \
            else o.tolist()
    if isinstance(o, np.generic):
        return o.item()
    return str(o)


def run_line(r):
    return (f"Open {r['iteration']} {r['mode']}, background {r['background']:g}: "
            f"{'PASS' if r['ok'] else 'FAIL'}, stimulus status {r['history']['actualStatus'][0]:.0f}, "
            f"deadline error {r['deadlineErrorMs']:.3f} ms, startup {len(r['startup']['status'])} attempts / "
            f"{r['startup']['seconds']:.3f} s, whole Open {r['openSeconds']:.3f} s\n"
            f"  Startup statuses: {' '.join(str(int(s)) for s in r['startup']['status'])}\n")


def save_report(report, base):
    with open(base + '.json', 'w') as f:
        json.dump(report, f, default=to_json)
    with open(base + '.txt', 'w') as f:
        f.write(f"Open readiness test {report['date']}\nNative {report['native']}\n"
                'Startup frames retained separately; no stimulus frames discarded.\n'
                'Scheduled checks allow the next refresh boundary plus 2 ms tolerance; software timing, '
                'not physical onset.\n')
        for r in report['runs']:
            f.write(run_line(r))
        passed = sum(r['ok'] for r in report['runs'])
        f.write(f"Passed {passed}/{len(report['runs'])} completed opens. Complete {int(report['complete'])}; "
                f"error {report['error']}\n")


def open_ready_test(repeats=10):
    if not (repeats == int(repeats) and 2 <= repeats <= 100):
        raise ValueError('repeats must be 2..100')
    base = time.strftime('PsychMetalOpenReady-%Y%m%d-%H%M%S')
    report = dict(date=time.strftime('%Y-%m-%d %H:%M:%S'), native=pm._core.__file__, runs=[], complete=False,
                  error='')
    escape = pm.kb_name('ESCAPE')
    w = None
    try:
        for k in range(1, int(repeats) + 1):
            down, _, keys = pm.kb_check()
            if down and keys[escape]:
                raise RuntimeError('Aborted with Escape')
            bg = (0, 32, 64)[(k - 1) % 3]
            opened = time.perf_counter()
            w, r, ifi = pm.open_window(None, bg)
            open_seconds = time.perf_counter() - opened
            before = pm.diagnostic(w)
            st = before['startup']
            assert len(st['status']) >= 2 and np.all(st['status'][-2:] == 0), 'Startup was not confirmed'
            assert before['actualStatus'].size == 0, 'Startup frames leaked into stimulus history'
            assert np.all(np.abs(before['summary']['backgroundColor'][:3] - bg / 255) < 1e-12), \
                'Wrong requested background'
            pm.fill_rect(w, 128, [r[2] * .4, r[3] * .4, r[2] * .6, r[3] * .6])
            target, mode = float('nan'), 'immediate'
            if k % 2 == 0:
                target, mode = pm.get_secs() + .25, 'scheduled'
            flip_error = ''
            try:
                if np.isfinite(target):
                    pm.flip(w, target)
                else:
                    pm.flip(w)
            except pm.PsychMetalError as err:
                if 'Presentation callback returned no timestamp.' not in str(err):
                    raise
                flip_error = str(err)
            d = pm.diagnostic(w)
            assert d['actualStatus'].size == 1, 'Expected exactly one stimulus record'
            confirmed = d['actualStatus'][0] == 0
            delta = (d['actualTimestamp'][0] - target) * 1000
            deadline_ok = not np.isfinite(target) or (np.isfinite(delta) and -.2 <= delta <= ifi * 1000 + 2)
            good = bool(confirmed and deadline_ok and not flip_error)
            time.sleep(.15)
            pm.close(w)
            w = None
            run = dict(iteration=k, mode=mode, background=bg, openSeconds=open_seconds, startup=st, target=target,
                       ifi=ifi, deadlineErrorMs=delta, history={k2: v for k2, v in d.items() if k2 != 'startup'},
                       flipError=flip_error, ok=good)
            report['runs'].append(run)
            save_report(report, base)
            print(run_line(run), end='')
        report['complete'] = True
    except BaseException as err:
        if w is not None:
            try:
                pm.close(w)
            except Exception:
                pass
        report['error'] = str(err)
        try:
            report['failedStartupRaw'] = pm._core.startup_history()
        except Exception:
            pass
        save_report(report, base)
        raise
    save_report(report, base)
    print(f'Saved {base}.txt and .json')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('repeats', nargs='?', type=int, default=10)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(open_ready_test, args.repeats, threaded=args.threaded)


if __name__ == '__main__':
    main()
