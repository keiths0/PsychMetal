#!/usr/bin/env python3
"""Keyboard taps retained during waits, through the background key queue.

Python port of PsychMetalKbQueueDemo.m:

    python3 kb_queue_demo.py           # 15 seconds
    python3 kb_queue_demo.py 30

No window and no display capture. Tap T quickly while the program waits half a
second per read; every tap is still reported, with its detection time. Escape
exits. Events are [detection time, key index, pressed], with 0-based key
indices as everywhere in the Python package (Escape is 40, T is 22).

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def kb_queue_demo(seconds=15):
    if not (np.isfinite(seconds) and seconds > 0):
        raise ValueError('seconds must be positive.')
    t, escape = pm.kb_name('t'), pm.kb_name('ESCAPE')
    mask = np.zeros(256)
    mask[[t, escape]] = 1
    pm.kb_queue_create(mask)
    events = np.zeros((0, 3))
    try:
        pm.kb_queue_start()
        print('Tap T during each half-second wait. Escape exits.')
        deadline = pm.get_secs() + seconds
        while pm.get_secs() < deadline:
            pm.wait_secs(0.5)
            new, dropped = pm.kb_queue_get_events()
            if dropped > 0:
                raise RuntimeError(f'Keyboard queue overflowed: {dropped} events lost.')
            for when, key, pressed in new:
                print(f"{when:.6f} key {int(key)} {'press' if pressed else 'release'}")
            events = np.vstack([events, new])
            if np.any((new[:, 1] == escape) & (new[:, 2] == 1)):
                break
    finally:
        pm.kb_queue_release()
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=15)
    args = parser.parse_args()
    kb_queue_demo(args.seconds)


if __name__ == '__main__':
    main()
