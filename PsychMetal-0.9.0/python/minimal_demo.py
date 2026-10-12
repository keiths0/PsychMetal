#!/usr/bin/env python3
"""Open, draw a rectangle in Metal, flip. Nothing else.

Python port of PsychMetalMinimalDemo.m:

    python3 minimal_demo.py            # 3 seconds
    python3 minimal_demo.py 10

The whole frame is produced by Metal: a full-window fill for the background,
then a red rectangle over it. Colours follow the window's colour range, which
opens at 255 as Screen's does.

SPDX-License-Identifier: MIT
"""
import argparse

import psychmetal as pm


def minimal_demo(seconds=3):
    w, rect, ifi = pm.open_window(None)       # None is the last active display
    try:
        pm.hide_cursor()
        box = [rect[2] * 0.30, rect[3] * 0.30, rect[2] * 0.70, rect[3] * 0.70]
        print(f'\nDrawing a red rectangle at {[round(v) for v in box]} for {seconds:g} seconds.')
        print('Everything on screen is drawn by Metal; no Screen drawing calls.')
        escape = pm.kb_name('ESCAPE')
        for _ in range(round(seconds / ifi)):
            if pm.kb_check()[2][escape]:
                break
            pm.fill_rect(w, [38, 38, 51])            # background, whole window
            pm.fill_rect(w, [230, 51, 38], box)
            pm.flip(w)
        d = pm.diagnostic(w)
    finally:
        pm.close(w)
        pm.show_cursor()
    s = d['summary']
    print(f"Shapes appended {s['shapesAppended']:.0f}, encoded {s['shapesEncoded']:.0f}.")
    # lastShapeColor is the FIRST shape of a batch, so it is the background.
    print(f"First shape of the last batch: {[round(float(c), 4) for c in s['lastShapeColor']]} "
          '(the background, 0-1).')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=3)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(minimal_demo, args.seconds, threaded=args.threaded)


if __name__ == '__main__':
    main()
