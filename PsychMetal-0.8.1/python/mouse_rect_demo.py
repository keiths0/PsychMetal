#!/usr/bin/env python3
"""A rectangle that follows the mouse, drawn in Metal.

Python port of PsychMetalMouseRectDemo.m:

    python3 mouse_rect_demo.py         # 20 seconds
    python3 mouse_rect_demo.py 60

Click any mouse button to stop early. get_mouse(w) returns the pointer in the
window's own pixel coordinates, so the rectangle tracks at the right speed on a
Retina display in a scaled mode.

Reports the interval from reading the mouse to the confirmed presentation of the
frame containing it, about two refreshes, most of which is the compositor.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def mouse_rect_demo(seconds=20):
    w, rect, ifi = pm.open_window(None)
    try:
        pm.hide_cursor()
        half = min(rect[2], rect[3]) * 0.12 / 2
        total = round(seconds / ifi)
        sample_time = np.full(total, np.nan)
        frames = 0
        print(f'\nMove the mouse. Click to stop. {seconds:g} seconds maximum.')
        for k in range(total):
            sample_time[k] = pm.get_secs()
            mx, my, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            frames = k + 1
            x = min(max(mx, 0), rect[2])
            y = min(max(my, 0), rect[3])
            box = [x - half, y - half, x + half, y + half]
            # Background, then a crosshair through the cursor, then the box on top.
            pm.fill_rect(w, [26, 28, 36])
            pm.draw_lines(w, [[0, rect[2], x, x], [y, y, 0, rect[3]]], 2, [64, 71, 89])
            pm.fill_rect(w, [242, 89, 64], box)
            pm.frame_rect(w, 255, box, 3)
            pm.flip(w)
        d = pm.diagnostic(w)
    finally:
        pm.close(w)
        pm.show_cursor()

    # Diagnostic row k corresponds to loop iteration k.
    n = min(frames, len(d['flipNumber']))
    st = pm.frame_stats(d, ifi)
    ok = (d['actualStatus'][:n] == 0) & np.isfinite(d['actualTimestamp'][:n])
    input_ms = (d['actualTimestamp'][:n][ok] - sample_time[:n][ok]) * 1000
    median_ms = float(np.median(input_ms)) if input_ms.size else float('nan')
    report = dict(ifi=ifi, frames=n, confirmed=st['confirmed'], achievedHz=st['achievedHz'],
                  skipped=st['skipped'], inputToPhotonsMedianMs=median_ms,
                  inputToPhotonsRefreshes=median_ms / (ifi * 1000), summary=d['summary'])
    print('\n===== mouse rectangle, drawn in Metal =====')
    print(f"Frames {n}; confirmed {int(ok.sum())}; skipped {report['skipped']}")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s")
    print(f"MOUSE -> PRESENTED median {median_ms:.3f} ms ({report['inputToPhotonsRefreshes']:.3f} refreshes)")
    print('About two refreshes, of which the compositor is most and drawing is\n'
          'the rest. The window prefetches its next drawable so that the wait for\n'
          'one happens before the mouse is read rather than after, which is worth\n'
          'a full refresh here. See docs/05_results.md section 9c.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(mouse_rect_demo, args.seconds, threaded=args.threaded)


if __name__ == '__main__':
    main()
