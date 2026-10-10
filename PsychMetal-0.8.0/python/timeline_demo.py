#!/usr/bin/env python3
"""Native frame-counted Gaussian flicker; no per-frame Python drawing.
Escape / three fingers exits. This fixed-scene demo does not support dragging.
"""
import argparse
import math
import numpy as np
import psychmetal as pm
from blob_array_demo import frame_periods, layout, measure_interval


def timeline_demo(seconds=20):
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('seconds must be positive and finite.')
    w, rect, nominal = pm.open_window()
    try:
        pm.background_color(w, 127.5)
        interval = measure_interval(w, nominal)
        frames = round(seconds / interval)
        if not 1 <= frames <= 1000000:
            raise ValueError('Duration must produce 1 to 1000000 frames.')
        periods = frame_periods(interval)
        centers, half, size = layout(rect[2]-rect[0], rect[3]-rect[1], len(periods))
        blob = pm.make_stimulus('grating', frequency=0, mean=.5,
                                contrast=1, aperture='gaussian', sigma=.3)
        # Queue all procedural draws first: indices 0..N-1 are unambiguous.
        for x, y in centers:
            pm.draw_stimulus(w, blob, [x-half, y-half, x+half, y+half])
        for (x, y), period in zip(centers, periods):
            text = f'{1 / (interval * period):.2f} Hz'
            pm.draw_text(w, text, x-half*.7, y+half, 255, size)
        tracks = np.array([[i, 1, 1, int(period), 360, 0]
                           for i, period in enumerate(periods)], dtype=float)
        print('Native timeline: Escape / three fingers stops; blobs stay in place.')
        result = pm.play_timeline(w, frames, tracks)
        # Collect after playback: drains pending frame results, without capture.
        history = pm.diagnostic(w)
        stats = pm.frame_stats(history, interval, max(0, len(history['actualStatus'])-result['submitted']))
        report = pm.environment_report()
        report['window'] = history['summary']
        print(f"{result['submitted']} submitted; {stats['achievedHz']:.3f} presentations/s; {stats['skipped']} long adjacent intervals.")
        print(f"The display reported {result['shown']} shown and {result['late']} late "
              f"({result['lateRefreshes']} refreshes lost). A sample stayed {result['meanSampleMs']:.3f} ms on average, "
              f"so the labelled frequencies ran at {1000 * interval / result['meanSampleMs']:.4f} of their value.")
        return dict(playback=result, frame_stats=stats, frame_periods=periods.tolist(),
                    frequencies=(1/(interval*periods)).tolist(), environment=report)
    finally:
        pm.close(w)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=20)
    parser.add_argument('--threaded', action='store_true')
    args = parser.parse_args()
    pm.run(timeline_demo, args.seconds, threaded=args.threaded)
