#!/usr/bin/env python3
"""Visual mouse check: buttons, edges and coordinates.

Python port of PsychMetalMouseTest.m:

    python3 mouse_test.py              # 30 seconds
    python3 mouse_test.py 60 1         # 60 seconds on display 1

Move to all edges; press, hold and release each button. Three boxes at the top
are LEFT, RIGHT and MIDDLE, green while held and grey otherwise. The crosshair
follows the pointer in render pixels. Escape or Q exits; clicks do not. The
console logs transitions; the report counts rising edges, not timing accuracy.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def mouse_test(seconds=30, screen=None):
    if not (np.isfinite(seconds) and seconds > 0):
        raise ValueError('seconds must be positive.')
    w, rect, _ = pm.open_window(screen, 20)
    try:
        W, H = rect[2], rect[3]
        s = min(W, H) * 0.05
        boxes = np.array([[W / 2 - 4 * s, 2 * s, W / 2 - 2 * s, 4 * s],
                          [W / 2 - s, 2 * s, W / 2 + s, 4 * s],
                          [W / 2 + 2 * s, 2 * s, W / 2 + 4 * s, 4 * s]]).T
        _, _, prev = pm.get_mouse(w)
        press_counts = np.zeros(3, dtype=int)
        samples = 0
        min_xy, max_xy = np.array([np.inf, np.inf]), np.array([-np.inf, -np.inf])
        escape, q = pm.kb_name('ESCAPE'), pm.kb_name('q')
        print('Mouse test: boxes LEFT, RIGHT, MIDDLE. Green means held. Q/Escape exits.')
        deadline = pm.get_secs() + seconds
        while pm.get_secs() < deadline:
            x, y, buttons = pm.get_mouse(w)
            assert buttons.dtype == bool and buttons.shape == (3,), 'Expected bool[3] button state.'
            assert np.isfinite(x) and np.isfinite(y), 'Nonfinite mouse coordinates.'
            samples += 1
            min_xy, max_xy = np.minimum(min_xy, [x, y]), np.maximum(max_xy, [x, y])
            press_counts += buttons & ~prev
            if np.any(buttons != prev):
                print(f'x={x:.1f} y={y:.1f}; left={buttons[0]:d} right={buttons[1]:d} middle={buttons[2]:d}')
            prev = buttons
            _, _, keys = pm.kb_check()
            if keys[escape] or keys[q]:
                break
            pm.fill_rect(w, 20)
            colours = np.where(buttons, np.array([[40], [230], [90]]), np.array([[80], [80], [80]]))
            pm.fill_rect(w, colours, boxes)
            pm.frame_rect(w, 220, boxes, 2)
            pm.draw_lines(w, [[0, W, x, x], [y, y, 0, H]], 2, [40, 200, 255])
            pm.frame_rect(w, 255, [x - s / 2, y - s / 2, x + s / 2, y + s / 2], 2)
            pm.flip(w)
    finally:
        pm.close(w)
    print(f'Observed button presses [left right middle]: {press_counts[0]} {press_counts[1]} {press_counts[2]}')
    return dict(samples=samples, pressCounts=press_counts, minXY=min_xy, maxXY=max_xy, rect=rect)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=30)
    parser.add_argument('screen', nargs='?', type=int, default=None)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(mouse_test, args.seconds, args.screen, threaded=args.threaded)


if __name__ == '__main__':
    main()
