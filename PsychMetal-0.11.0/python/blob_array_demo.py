#!/usr/bin/env python3
"""Draggable Gaussian blobs, counterphasing from refresh/2 down to about 1 Hz.

Run: python3 blob_array_demo.py [seconds=60] [contrast=0.5]
Left-button drag on Mac; one-finger drag on iOS. Escape / three fingers stops.
Frequencies use the measured refresh grid: one waveform sample per submitted frame. Missed
refreshes slow the sequence; the returned frame statistics expose those misses.
Cosine starts at a peak so the Nyquist blob alternates white/black every frame.
Overlap uses ordinary alpha compositing; isolated blobs span 0.5 +/- contrast.
SPDX-License-Identifier: MIT
"""
import argparse
import math
import sys

import numpy as np
import psychmetal as pm


def frame_periods(ifi):
    """Even frame counts: octave spacing plus six frames to show two midtones."""
    if not math.isfinite(ifi) or ifi <= 0:
        raise ValueError('A positive measured refresh interval is required.')
    count = max(1, int(math.floor(math.log2(0.5 / ifi) + 0.5)) + 1)
    periods = 2 ** np.arange(1, count + 1, dtype=np.int64)
    return np.unique(np.append(periods, 6)) if periods[-1] >= 8 else periods


def frequencies(ifi):
    return 1.0 / (ifi * frame_periods(ifi))


def waveform_samples(periods):
    """Uniform phase samples, including exact positive and negative peaks."""
    tables = []
    for n in periods:
        values = np.cos(2 * np.pi * np.arange(n) / n)
        values[0], values[n // 2] = 1., -1.
        if n % 4 == 0:
            values[n // 4] = values[3 * n // 4] = 0.
        tables.append(values)
    return tables


def measure_interval(w, nominal):
    # Populate the engine's confirmed-frame grid estimator before reading it.
    # This is calibration, not part of the demo's stimulus frame count.
    for _ in range(max(60, round(1.0 / nominal))):
        pm.fill_rect(w, 127.5)
        pm.flip(w)
    _, period, samples = pm.grid_anchor(w)
    if samples < 30 or not math.isfinite(period) or period <= 0:
        raise RuntimeError("Could not measure the display refresh rate from confirmed frames.")
    return period


def layout(width, height, count):
    cols = min(count, max(1, math.ceil(math.sqrt(count * width / height))))
    rows = math.ceil(count / cols)
    cw, ch = width / cols, height / rows
    half = min(cw * 0.42, ch * 0.32)
    centers = np.array([[(i % cols + .5) * cw, (i // cols + .43) * ch]
                        for i in range(count)])
    return centers, half, max(12, min(cw * .08, ch * .08))


class Drag:
    """One active pointer, offset-preserving drag, topmost circular hit target."""
    def __init__(self, centers, radius):
        self.centers = centers
        self.radius = radius
        self.order = list(range(len(centers)))
        self.active = None
        self.pointer = None
        self.offset = np.zeros(2)

    def down(self, pointer, x, y):
        if self.pointer is not None:
            return
        # Capture even a miss until release: sliding in while held is not a press.
        self.pointer = pointer
        for i in reversed(self.order):
            if np.linalg.norm(self.centers[i] - [x, y]) <= self.radius:
                self.active = i
                self.offset = self.centers[i] - [x, y]
                self.order.remove(i)
                self.order.append(i)
                break

    def move(self, pointer, x, y):
        if pointer == self.pointer and self.active is not None:
            self.centers[self.active] = np.array([x, y]) + self.offset

    def up(self, pointer):
        if pointer == self.pointer:
            self.active = self.pointer = None


def blob_array_demo(seconds=60, contrast=0.5, diagnostic=True, inspect_frames=False, presentation="auto"):
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('seconds must be positive and finite.')
    if not math.isfinite(contrast) or not 0 < contrast <= .5:
        raise ValueError('contrast must be in (0, 0.5].')
    w, rect, ifi = pm.open_window(None, readback=bool(diagnostic and inspect_frames), presentation=presentation)
    try:
        ifi = measure_interval(w, ifi)
        inspector = None
        if diagnostic and inspect_frames:
            from psychmetal.inspection import Inspector
            inspector = Inspector(w, rect, ifi)
        periods = frame_periods(ifi)
        tables = waveform_samples(periods)
        hz = frequencies(ifi)
        centers, half, size = layout(rect[2] - rect[0], rect[3] - rect[1], len(hz))
        drag = Drag(centers, half)
        labels = [f'{f:.2f} Hz' for f in hz]
        widths = [pm.text_bounds(w, label, size)[0][2] for label in labels]
        escape = pm.kb_name('ESCAPE')
        touch = sys.platform == 'ios'
        held = False
        frames = 0
        dropped_events = 0
        print('Blob array: ' + ', '.join(labels))
        print('Hold and drag a blob; release to leave it. Escape / three fingers stops.')
        for k in range(max(1, round(seconds / ifi))):
            if pm.kb_check()[2][escape]:
                break
            if touch:
                events, dropped = pm.touch_events(w)
                dropped_events += dropped
                if dropped:
                    drag.up(drag.pointer)  # A release may have been lost.
                for _, finger, phase, x, y in events:
                    if phase == 0:
                        drag.down(finger, x, y)
                    elif phase == 1:
                        drag.move(finger, x, y)
                    elif phase in (2, 3):
                        if phase == 2:
                            drag.move(finger, x, y)
                        drag.up(finger)
            else:
                x, y, buttons = pm.get_mouse(w)
                pressed = bool(buttons[0])
                if pressed and not held:
                    drag.down(0, x, y)
                if pressed or held:
                    drag.move(0, x, y)
                if not pressed:
                    drag.up(0)
                held = pressed
            pm.fill_rect(w, 127.5)
            amplitudes = contrast * np.array([table[k % len(table)] for table in tables])
            for i in drag.order:
                x, y = centers[i]
                s = amplitudes[i]
                value = 255 if s >= 0 else 0
                pm.draw_gabor(w, [value, value, value, 510 * abs(s)],
                              [x-half, y-half, x+half, y+half], .30)
                pm.draw_text(w, labels[i], x-widths[i]/2, y+half, 0, size)
            pm.flip(w)
            frames += 1
            if inspector is not None:
                if not inspector.capture():
                    break
                if inspector.resumed:
                    drag.up(drag.pointer)
                    held = False
        stats = None
        if diagnostic and inspector is None:
            history = pm.diagnostic(w)
            stats = pm.frame_stats(history, ifi, max(0, len(history['actualStatus'])-frames))
    finally:
        pm.close(w)
    if stats is not None:
        print(f"{frames} frames; {stats['achievedHz']:.3f} presentations/s; {stats['skipped']} long frame intervals.")
    return dict(presentation=presentation, ifi=ifi, frequencies=hz, frame_periods=periods, frames=frames, centers=centers.copy(),
                frame_stats=stats, dropped_touch_events=dropped_events)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('seconds', nargs='?', type=float, default=60)
    parser.add_argument('contrast', nargs='?', type=float, default=.5)
    parser.add_argument('--presentation', choices=('auto','direct','displaylink'), default='auto')
    parser.add_argument('--threaded', action='store_true')
    parser.add_argument('--inspect-frames', action='store_true', help='Capture and pause on missed refreshes; adds timing overhead.')
    args = parser.parse_args()
    pm.run(blob_array_demo, args.seconds, args.contrast, inspect_frames=args.inspect_frames, threaded=args.threaded, presentation=args.presentation)


if __name__ == '__main__':
    main()
