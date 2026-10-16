#!/usr/bin/env python3
"""Write a drifting Gabor movie without opening a presentation window.

    python3 export_demo.py stimulus.mp4 --seconds 3
Requires a Metal GPU and an available H.264 encoder.
"""
import argparse
import math
import psychmetal as pm


def export_demo(path='psychmetal_export.mp4', seconds=3):
    if not math.isfinite(seconds) or not 0 < seconds <= 60:
        raise ValueError('seconds must be positive and at most 60.')
    with pm.open_export(640, 480, refresh_hz=60, color=127) as (w, rect, ifi):
        pm.start_movie_recording(w, path, codec='h264', sound=False, clock='virtual')
        for frame in range(max(1, round(seconds / ifi))):
            pm.draw_gabor(w, None, [160, 80, 480, 400], .5, .04, 30, frame * 6)
            pm.flip(w)
        report=pm.stop_movie_recording(w)
    report["exportedMovie"]=True
    print(f"Movie saved: {report['frames']:.0f} frames, {report['duration']:.3f} s: {report['path']}")
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', nargs='?', default='psychmetal_export.mp4')
    parser.add_argument('--seconds', type=float, default=3)
    args = parser.parse_args()
    report = export_demo(args.path, args.seconds)
    print(f"Wrote {report['frames']:.0f} frames, {report['duration']:.3f} s: {report['path']}")
