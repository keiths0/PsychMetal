#!/usr/bin/env python3
"""Manual display acceptance plus session and texture lifecycle checks.

Python port of PsychMetalHardwareTest.m:

    python3 hardware_test.py

The visible frame should show dark grey on the left, white in the middle and
green on the right for three seconds, then a blue frame for one second. Run on
a physical display in a fresh Python process.

Checked along the way: a texture's queued draw keeps the image it had when
drawn (the left panel is drawn before the texture is updated to white and then
closed), handles are never reused, a closed texture and a closed window are
refused, and closing after prepare_flip followed by reopening works.

SPDX-License-Identifier: MIT
"""
import argparse
import time

import numpy as np

import psychmetal as pm


def reject(fn, what):
    try:
        fn()
    except Exception:
        return
    raise AssertionError(f'{what} was accepted')


def hardware_test():
    w, r, _ = pm.open_window()
    try:
        old_window, W, H = w, r[2], r[3]
        tex = pm.make_texture(w, np.full((64, 64), 0.25, dtype=np.float32))
        pm.draw_texture(w, tex, None, [0, 0, W / 3, H])
        pm.update_texture(w, tex, np.full((64, 64), 255, dtype=np.uint8))
        pm.draw_texture(w, tex, None, [W / 3, 0, 2 * W / 3, H])
        pm.close_texture(w, tex)
        green = np.zeros((64, 64, 3), dtype=np.float32)
        green[:, :, 1] = 1
        following = pm.make_texture(w, green)
        assert following != tex, 'Texture handle was reused'
        reject(lambda: pm.draw_texture(w, tex), 'A stale texture handle')
        pm.draw_texture(w, following, None, [2 * W / 3, 0, W, H])
        pm.flip(w)
        time.sleep(3)
        pm.prepare_flip(w)
        pm.close(w)
        w = None
        w, r, _ = pm.open_window()
        assert w != old_window, 'Window handle was reused'
        reject(lambda: pm.flip(old_window), 'A stale window handle')
        pm.fill_rect(w, [0, 0, 255], r)
        pm.prepare_flip(w)
        pm.present_now(w)
        time.sleep(1)
        pm.close(w)
        w = None
    finally:
        if w is not None:
            try:
                pm.close(w)
            except Exception:
                pass
    print('PASS: texture snapshots/handles and close-after-prepare/reopen calls completed.')
    print('Visual acceptance requires grey | white | green, then a blue frame.')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(hardware_test, threaded=args.threaded)


if __name__ == '__main__':
    main()
