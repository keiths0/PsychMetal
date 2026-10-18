#!/usr/bin/env python3
"""Recording what PsychMetal draws to a movie, then playing the movie back.

Python port of PsychMetalRecordDemo.m:

    python3 record_demo.py                          # psychmetal_recording.mov, ProRes 4444
    python3 record_demo.py clip.mp4 --codec hevc
    python3 record_demo.py --seconds 5 --scale 0.5

Part 1 draws a drifting Gabor patch, a dot circling at one turn a second and a
frame counter for a few seconds, recording every frame. The dot passes three
o'clock every second, and with audio a click is scheduled for each pass. At the
first click, and every other one after it, the program draws nothing new for
half a second: the frame with the dot at three o'clock stays on the screen, and
in the movie it lasts just as long. Then the motion carries on from where it
stopped, and the later clicks come half a second later to match.

Part 2 opens the movie it just wrote and shows it again, smaller and on black,
each frame at its time in the movie and with the movie's own sound track, so
the pause and the clicks come back as they were. It checks the movie's frame
times against flip's and the clicks against their scheduled times.

The recording clock is virtual by default: flip returns the movie's timeline, and
time spent copying and encoding frames does not move frames in the movie. With
--clock live, flip returns the display's refreshes and the movie records the
screen's own timing, late frames included.

Escape (or three fingers) ends part 1 early.

SPDX-License-Identifier: MIT
"""
import argparse
from bisect import bisect_right
import math
from pathlib import Path

import numpy as np

import psychmetal as pm
from audio_demo import safe_area


def _replay_recording(w, movie, times, box, track, ifi):
    """Decode the first picture BEFORE scheduling the shared A/V start.

    Keep the recorded (possibly irregular) timestamps: PlayMovie's constant
    refreshes-per-frame cadence would shorten the intentional held frame.
    """
    pm.fill_rect(w, 0)
    pm.draw_movie_frame(w, movie, 0, None, box)
    start = pm.next_refresh(w, pm.get_secs() + max(.1, 6 * ifi))
    if track is not None:
        pm.play(track, start)
    late = skipped = shown = 0
    max_late = 0.
    k = 0
    decode_budget = 0.
    while k < len(times):
        if k:
            # Audio owns one continuous wall-clock timeline. Replaying expired
            # frames one by one would slow video while audio continues normally.
            # This affects the preview only; every frame remains in the file.
            # Use the preceding decode cost to choose the picture due when
            # this decode is expected to finish, rather than staying one decode late.
            due = bisect_right(times, times[0] + pm.get_secs() + decode_budget - start) - 1
            newest = min(len(times) - 1, max(k, due))
            skipped += newest - k
            k = newest
            decode_began = pm.get_secs()
            pm.fill_rect(w, 0)
            pm.draw_movie_frame(w, movie, k, None, box)
            decode_budget = max(0., pm.get_secs() - decode_began)
        aim = start + times[k] - times[0]
        seen = pm.flip(w, aim)[0]
        delay = max(0., seen - aim)
        late += delay > .5 * ifi
        max_late = max(max_late, delay)
        shown += 1
        k += 1
    return dict(frames=shown, skipped=skipped, late=int(late),
                maxLateMs=1000 * max_late, elapsed=pm.get_secs() - start)


def record_demo(path='psychmetal_recording.mov', codec='prores4444', seconds=3.0, scale=1.0, clock='virtual'):
    path = Path(path).expanduser().resolve()
    w, rect, ifi = pm.open_window(None, 128)
    try:
        pm.hide_cursor()
        W, H = rect[2], rect[3]
        r = min(W, H) * .2
        area = safe_area(w, rect)
        text_x, text_y = max(W * .05, area[0] + 12), max(H * .05, area[1] + 12)
        escape = pm.kb_name('ESCAPE')
        try:
            pm.open_audio(routes='any')
            click = pm.make_sound(pm.click(pm.audio_status()['info']['rate']))
        except pm.PsychMetalError:
            click = None            # no wired output: the movie is recorded without sound
        print(f"\nPart 1: the stimulus, recorded to {path.name}. On the first click it stops for half a second on"
              "\n        purpose: the frame stays up, the movie must hold it as long, and the motion resumes where it stopped.")
        pm.start_movie_recording(w, path, codec, scale, clock=clock)
        frames = paused = 0
        began = vbl = pm.flip(w)[0]
        shown = [vbl]               # when each frame was aimed, as flip reported it
        frames += 1
        # The stimulus's own time stops during a pause: `held` is the time spent paused.
        # A pause comes after the frame on each odd second (each other click) before the end.
        pause_len = round(.5 / ifi) * ifi
        pause_at = [k for k in range(1, int(math.ceil(seconds))) if k % 2 == 1]
        # The click frame stays up for `pause_len` instead of one refresh, so the stimulus falls
        # behind by pause_len - ifi at each pause; the click for second k comes after those before it.
        click_times = [k + (pause_len - ifi) * (k // 2) for k in range(1, int(seconds) + 1)]
        if click is not None:
            for c in click_times:
                pm.play(click, began + c)
        held, pause_next = 0.0, False
        while True:
            if pm.kb_check()[2][escape]:
                break
            t = vbl + ifi - began - held           # the stimulus time of the frame drawn now
            if t > seconds + ifi / 2:
                break
            pm.fill_rect(w, 128)
            # sigma .3 of a half-size of 1.3 r: the envelope is under 1% of its peak at the square's
            # edges, so the patch fades into the background and looks round.
            g = 1.3 * r
            pm.draw_gabor(w, None, [W / 2 - g, H / 2 - g, W / 2 + g, H / 2 + g], .3, 6 / r, 0, 360 * t)
            angle = 2 * math.pi * t
            x, y = W / 2 + 1.4 * r * math.cos(angle), H / 2 + 1.4 * r * math.sin(angle)
            pm.fill_oval(w, [230, 60, 50], [x - r / 8, y - r / 8, x + r / 8, y + r / 8])
            size = max(14, H * .04)
            pm.draw_text(w, f'frame {frames}', text_x, text_y, 255, size)
            pm.draw_text(w, f'{t:6.3f} s', text_x, text_y + 1.3 * size, 255, size)
            if pause_next:
                # Half a second with nothing new: the frame with the click stays up, here and in
                # the movie, and this frame, the next step of the motion, comes after it.
                before = vbl
                vbl = pm.flip(w, vbl + pause_len)[0]
                held += vbl - before - ifi
                paused += 1
                pause_next = False
            else:
                vbl = pm.flip(w)[0]
                if pause_at and t >= pause_at[0] - ifi / 2:
                    pause_at.pop(0)
                    pause_next = True
            shown.append(vbl)
            frames += 1
        rec = pm.stop_movie_recording(w)
        # What the display reported for the same frames: [token, status, presented, committed], oldest first.
        pm.wait_secs(.2)
        reports = np.asarray(pm.recent_frames(w, min(256, len(shown))))[-len(shown):]
        print(f"        {rec['frames']:.0f} frames recorded over {rec['refreshes']:.0f} refreshes "
              f"({rec['duration']:.3f} s at {rec['refreshHz']:.2f} Hz) to {path.name}, {rec['codec']}, "
              f"{rec['width']:.0f} x {rec['height']:.0f}; {paused} half-second pauses.")
        print(f"        {rec['late']:.0f} frames were shown late live (the copy and the encoder add work); "
              "in the movie every frame is at the refresh it was aimed at.")
        print(f"        Sound: {rec['soundSeconds']:.3f} s on the track ({rec['soundLostSeconds']:.3f} s lost)."
              if rec['sound'] else "        Sound: none (audio was not open).")

        movie, info = pm.open_movie(w, path)
        times = pm.movie_frame_times(movie)
        steps = sorted(set(np.round(np.diff(times) * rec['refreshHz'], 3).tolist()))
        print(f"Part 2: the movie has {info['frames']:.0f} frames; they are {steps} refreshes apart.")
        # The movie's frame times against flip's: they should agree to the refresh, frame for frame.
        n = min(len(times), len(shown))
        offsets = np.round((times[:n] - times[0] - (np.array(shown[:n]) - shown[0])) * rec['refreshHz'], 3)
        worst = float(np.abs(offsets).max()) if n else float('nan')
        virtual = bool(rec.get('virtualClock'))
        # With the virtual clock, flip returns the movie's own timeline, so this agrees by
        # construction; with the live clock, flip returns the display's refreshes.
        print(f"        Against the times flip returned{' (the virtual clock: the same timeline as the movie)' if virtual else ' live'}: "
              f"the largest difference is {worst:g} refreshes"
              + (" (as it should be)." if worst == 0 and len(times) == len(shown) else
                 f"; {len(times)} frames in the movie, {len(shown)} flipped."))
        # And against what the display reported showing: the times the participant saw.
        seen = (reports[:, 1] == 0) & (reports[:, 2] > 0)
        if len(reports) == n and seen.any():
            k0 = int(np.flatnonzero(seen)[0])
            movie_rel = times[:n] - times[k0]
            display_rel = reports[:, 2] - reports[k0, 2]
            flip_rel = np.array(shown[:n]) - shown[k0]
            against_display = np.round((movie_rel - display_rel)[seen] * rec['refreshHz'], 3)
            print(f"        Against what the display reported showing ({int(seen.sum())} of {n} frames reported): "
                  f"the largest difference is {float(np.abs(against_display).max()):g} refreshes.")
            if virtual:
                # Virtual times are not display times: subtracting them measures the gap between
                # the two clocks, not lateness (MOVIES.md, Virtual clock).
                print(f"        {rec['late']:.0f} frames reached the screen late; with the virtual clock the movie "
                      "keeps every frame at its intended refresh. --clock live records the screen's timing.")
            else:
                # Absolute: the time each flip returned against the display's report of the same frame.
                absolute = np.round((reports[:, 2] - np.array(shown[:n]))[seen] * rec['refreshHz'], 2)
                values, counts = np.unique(absolute, return_counts=True)
                print('        Display report minus the time flip returned, frame by frame (refreshes): ' +
                      ', '.join(f'{v:+.2f} for {c}' for v, c in zip(values, counts)) + '.')
            odd = np.flatnonzero(np.abs(np.round((movie_rel - flip_rel) * rec['refreshHz'])) > 0)
            for k in odd[:4]:
                print(f"          frame {k}: movie {movie_rel[k] * rec['refreshHz']:.2f}, flip returned "
                      f"{flip_rel[k] * rec['refreshHz']:.2f}, display "
                      + (f"{display_rel[k] * rec['refreshHz']:.2f}" if seen[k] else "no report")
                      + " refreshes after frame %d" % k0)
        clicks = []
        if info['soundChannels']:
            # Each click's first sample, by the movie's clock: it should be at its scheduled time.
            loud = np.flatnonzero(np.abs(pm.movie_sound(movie)[:, 0]) > .5)
            starts = loud[np.r_[True, np.diff(loud) > info['soundRate'] / 10]] if loud.size else loud
            clicks = (starts / info['soundRate']).tolist()
            expected = [min(click_times, key=lambda e: abs(e - c)) for c in clicks]
            print('        Clicks on the sound track at ' + ', '.join(f'{c:.4f}' for c in clicks) +
                  ' s, scheduled for ' + ', '.join(f'{e:.4f}' for e in expected) + ' s: off by ' +
                  ', '.join(f'{1000 * (c - e):+.2f}' for c, e in zip(clicks, expected)) + ' ms.'
                  if clicks else '        No clicks on the sound track.')
        size = min(1, .9 * W / info['width'], .9 * H / info['height'])
        box = [(W - info['width'] * size) / 2, (H - info['height'] * size) / 2,
               (W + info['width'] * size) / 2, (H + info['height'] * size) / 2]
        print("        Replaying the movie from the file, smaller and on black, with its own sound track:")
        track = None
        if info['soundChannels'] and click is not None:
            track = pm.make_sound(pm.movie_sound(movie, pm.audio_status()['info']['rate']))
        # Warm the bounded decode ring before scheduling preview audio.
        capacity = min(8, max(1, int(256*1024*1024/(info['width']*info['height']*4))))
        pm.prepare_movie(w, movie, frames=capacity)
        try:
            play = _replay_recording(w, movie, times, box, track, ifi)
        finally:
            if track is not None:
                pm.close_sound(track)
        print(f"        Preview: {play['frames']} frames shown, {play['skipped']} preview frames skipped; "
              f"{play['elapsed']:.3f} s elapsed to the last frame, "
              f"{times[-1]-times[0]:.3f} s in the file; maximum video delay {play['maxLateMs']:.2f} ms.")
        if play['skipped'] or play['late']:
            print("        Replay could not show every frame on time. The preview follows the audio clock; "
                  "the saved movie still contains every recorded frame.")
        pm.close_movie(movie)
    finally:
        pm.close(w)
        pm.show_cursor()
        try:
            pm.close_audio()
        except Exception:
            pass
    return dict(recording=rec, frames=frames, paused=paused, movieFrames=info['frames'], steps=steps, play=play,
                clicks=clicks, worst=worst)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('path', nargs='?', default='psychmetal_recording.mov')
    parser.add_argument('--codec', default='prores4444', choices=['prores4444', 'prores422', 'hevc', 'h264'])
    parser.add_argument('--seconds', type=float, default=3.0)
    parser.add_argument('--scale', type=float, default=1.0)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    parser.add_argument('--clock', default='virtual', choices=['live','virtual'])
    args = parser.parse_args()
    pm.run(record_demo, args.path, args.codec, args.seconds, args.scale, args.clock, threaded=args.threaded)


if __name__ == '__main__':
    main()
