#!/usr/bin/env python3
"""A movie, frame by frame: played whole, then drawn inside a stimulus.

Python port of PsychMetalMovieDemo.m:

    python3 movie_demo.py                         # the test movie make test writes
    python3 movie_demo.py ~/Movies/clip.mov
    python3 movie_demo.py clip.mp4 --sound stretch

Any movie macOS reads (.mov, .mp4, .m4v; H.264, HEVC, ProRes and the rest).

Part 1 plays the movie with play_movie: every frame for the same whole number of
refreshes, the nearest to the refresh rate over the movie's frame rate. A 30 fps
movie on a 60 Hz display shows each frame for 2 refreshes and plays at its own
rate; a 24 fps movie shows each for 3 and plays at 20 fps, and says so. Nothing
is dropped or shown longer than the rest. The report says what the display
reported: frames shown, and any shown late.

Part 2 draws the frames with draw_movie_frame, which works like draw_texture, so
a movie can be one element of a stimulus: here it turns slowly inside a frame,
with its frame number written under it, stepping one movie frame every
`refreshes` refreshes.

--sound: auto (default: the movie's sound when it plays at its own rate),
off, resample (sound follows the frames' rate, its pitch with it) or stretch
(sound follows the frames' rate at its own pitch).

Escape (or three fingers) ends either part early.

SPDX-License-Identifier: MIT
"""
import argparse
from pathlib import Path

import psychmetal as pm

DEFAULT = Path(__file__).resolve().parent.parent / 'tests' / 'movies' / 'frames_h264.mp4'


def movie_demo(path=None, sound='auto'):
    path = DEFAULT if path is None else Path(path).expanduser()
    w, rect, ifi = pm.open_window(None, 0)
    try:
        pm.hide_cursor()
        audio = True
        try:
            pm.open_audio()
        except pm.PsychMetalError:
            audio = False           # no wired output: the frames play without the sound
        movie, info = pm.open_movie(w, path)
        print(f"\n{path.name}: {info['width']:.0f} x {info['height']:.0f}, {info['frames']:.0f} frames at "
              f"{info['frameRate']:.3f} per second ({info['codec']}), "
              + (f"sound {info['soundChannels']:.0f} channels at {info['soundRate']:.0f} Hz."
                 if info['soundChannels'] else 'no sound.'))
        if not info['constantRate']:
            print('The frames are not evenly spaced in time; each is still shown for the same number of refreshes.')
        W, H = rect[2], rect[3]
        scale = min(1, .8 * W / info['width'], .7 * H / info['height'])
        mw, mh = info['width'] * scale, info['height'] * scale
        box = [(W - mw) / 2, (H - mh) / 2, (W + mw) / 2, (H + mh) / 2]

        # Part 1: the whole movie.
        report = pm.play_movie(w, movie, dst_rect=box, sound=sound if audio else 'off')
        print(f"Part 1: {report['frames']} frames, each for {report['refreshes']} refreshes of "
              f"{report['expectedRefreshHz']:.2f} Hz: {report['rate']:.3f} frames per second "
              f"(the movie's own: {info['frameRate']:.3f}). Sound: {report['sound']}.")
        print(f"        The display reported {report['shown']} of {report['submitted']} refreshes; "
              f"{report['late']} late, by {report['lateRefreshes']} refreshes in all; "
              f"longest interval {report['longestIntervalMs']:.1f} ms.")

        # Part 2: one element of a stimulus.
        k = report['refreshes']
        escape = pm.kb_name('ESCAPE')
        frames = int(info['frames'])
        shown = 0
        size = max(14, H * .03)
        for i in range(frames * k):
            if pm.kb_check()[2][escape]:
                break
            index = i // k
            angle = 10 * (i / (frames * k)) - 5
            pm.fill_rect(w, 40)
            pm.frame_rect(w, [255, 200, 0], [box[0] - 8, box[1] - 8, box[2] + 8, box[3] + 8], 4)
            pm.draw_movie_frame(w, movie, index, None, box, angle)
            label = f'frame {index} of {frames}'
            width = pm.text_bounds(w, label, size)[0][2]
            pm.draw_text(w, label, (W - width) / 2, box[3] + 16, [220, 220, 220], size)
            pm.flip(w)
            shown += 1
        print(f'Part 2: {shown} refreshes, the movie turning inside a frame, one movie frame every {k}.')
        pm.close_movie(movie)
    finally:
        pm.close(w)
        pm.show_cursor()
        try:
            pm.close_audio()
        except Exception:
            pass
    return dict(play=report, refreshes=shown)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('path', nargs='?', default=None, help='a movie file (default: the test movie)')
    parser.add_argument('--sound', default='auto', choices=['auto', 'off', 'resample', 'stretch'])
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(movie_demo, args.path, args.sound, threaded=args.threaded)


if __name__ == '__main__':
    main()
