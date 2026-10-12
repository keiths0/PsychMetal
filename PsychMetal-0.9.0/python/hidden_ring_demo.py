"""A hidden ring: grey noise with a ring of other noise in it, invisible while
the two hold still together, revealed by moving it.

    python3 hidden_ring_demo.py                       # 20 s, drifting 1 pixel per frame, 1-pixel cells
    python3 hidden_ring_demo.py 30 --speed 0 --cell 3

MATLAB and Octave: PsychMetalHiddenRingDemo(seconds, speed, cell). The phone app
offers the same two settings on the demo's start page.

The background is a fixed noise image in a centered square, with black outside.
The ring holds a second fixed noise image and moves with the pointer (the mouse
on a Mac, a finger on a phone), by the same amount, from wherever it is: a
finger put down does not fetch it. It can move anywhere in the window, including
the black margins. A click (a second finger on a phone) or the space bar changes
the ring to a drifting grating and back. Escape (three fingers) ends it. Neither
noise image is made or uploaded: each value is computed on the GPU from the seed
and the pixel's place in the rectangle drawn, so moving a rectangle moves its
image.

speed is how many pixels the background drifts sideways each frame; 0 is still.
The ring rides along with it, at the same rate, and the pointer's movement is
added to that. It is then never drawn in the same place on two frames running:
where the pointer's movement would exactly undo the drift, it is drawn a step
back, and is where the pointer has it on the next frame. A ring that leaves one
side comes in at the other.

cell is the width of a noise cell in pixels. The ring is made of whole cells and
is only ever a whole number of cells from the background's corner, so its cells
lie on the background's and its edge cuts none of them: with cells of 3 it moves
in steps of 3 pixels. With a hard edge and whole cells every pixel shows one
image or the other, so a ring that is not moving against the background cannot
be seen.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def hidden_ring_demo(seconds=20.0, speed=1, cell=1):
    if not (np.isfinite(seconds) and seconds > 0):
        raise ValueError('seconds must be positive.')
    if not (float(speed) == int(speed) and speed >= 0):
        raise ValueError('speed must be a whole number of pixels per frame, 0 or more.')
    if not (float(cell) == int(cell) and cell >= 1):
        raise ValueError('cell must be a whole number of pixels, 1 or more.')
    scroll, grain = int(speed), int(cell)
    with pm.open_window() as (w, rect, ifi):
        width, height = float(rect[2]), float(rect[3])
        side = min(width, height)
        # Whole-pixel square, centered to within half a pixel on odd dimensions.
        bx, by = (width-side)//2, (height-side)//2
        square = [bx, by, bx+side, by+side]
        background = pm.make_stimulus('noise', seed=13, grain=grain)
        noise = pm.make_stimulus('noise', seed=37, grain=grain)
        grating = pm.make_stimulus('grating', frequency=.025, contrast=.9)
        # The ring, uploaded once, with one texel for each pixel it covers.
        cells = 2 * round(side / 4 / grain)             # the ring is half the square across,
        size = cells * grain                            # a whole number of cells
        y, x = np.mgrid[:cells, :cells] + 0.5 - cells / 2
        r = np.sqrt(x * x + y * y) / (cells / 2)
        mask = pm.make_texture(w, np.kron((r >= .55) & (r <= 1), np.ones((grain, grain))).astype(np.float32))
        # A scrolling background's rectangle is wider than the square by its
        # scroll for every frame of the run, and starts that far off to the left.
        run = int(np.ceil(seconds / ifi)) + 2
        around = int(np.ceil(width / grain)) * grain    # a ring that leaves one side comes in this far back
        pm.set_mouse(w, width / 2, height / 2)
        space, escape = pm.kb_name('space'), pm.kb_name('ESCAPE')
        times, touches, why = [], Touches(), 'time'
        show_noise, switch_was = True, False
        # Where the ring's corner is, from the background's corner. The ring is
        # drawn a whole number of cells from it; held there, it scrolls with it.
        ring_x, ring_y = (width - size) / 2 + scroll * run, (height - size) / 2
        last_x, last_y, settle, drawn = width / 2, height / 2, 0, None
        began = vbl = pm.flip(w)[0]
        while vbl - began < seconds and len(times) < run:
            px, py, buttons = pm.get_mouse(w)
            # A finger going down takes the pointer to it. That step is not a
            # movement, and may show in this frame's pointer or the next's.
            if touches.read(w):
                settle = 2
            if settle:
                settle -= 1
            else:
                ring_x += px - last_x
                ring_y = float(np.clip(ring_y + py - last_y, 0, height - size))
            last_x, last_y = px, py
            if not scroll:
                ring_x = float(np.clip(ring_x, 0, width - size))
            _, _, keys = pm.kb_check()
            if keys[escape]:
                why = 'Escape'
                break
            # The switch works when it is let go: three fingers pass through two.
            switch = bool(buttons[0] or keys[space])
            show_noise ^= switch_was and not switch
            switch_was = switch
            edge = scroll * (len(times) - run)          # the background's left edge on this frame
            left = bx + edge + grain * round((ring_x-bx) / grain)
            top = by + grain * round((ring_y-by) / grain)
            if scroll and drawn == (left, top):
                left -= grain                           # never still on the screen
            drawn = (left, top)
            pm.fill_rect(w, [0, 0, 0])
            # Scroll the carrier under a fixed square aperture. Clear the clip
            # before drawing the ring so it can cross into the black margins.
            pm.clip(w, square)
            pm.draw_stimulus(w, background, [bx+edge, by, bx+edge+scroll*run+side, by+side])
            pm.clip(w, None)
            left %= around
            for x in (left, left - around, left + around):                      # the ring, and it coming round
                if x < width and x + size > 0:
                    pm.draw_stimulus(w, noise if show_noise else grating, [x, top, x + size, top + size], mask,
                                     phase=-180 * (vbl - began), orientation=30)
            vbl = pm.flip(w)[0]
            times.append(vbl)
        dropped = pm.flip_info(w)['droppedFrames']
        timing = pm.diagnostic(w)
    return report(width, height, ifi, times, dropped, touches, why, timing)



class Touches:
    """What touch_events has reported: how many events, the fingers that are down,
    and the most there have been at once."""

    def __init__(self):
        self.count, self.down, self.most = 0, set(), 0

    def read(self, w):
        """Take the events since the last call. True if a finger went down with none down."""
        events, _ = pm.touch_events(w)
        self.count += len(events)
        landed = False
        for _, finger, phase, _, _ in events:
            if phase == 0:
                landed |= not self.down
                self.down.add(finger)
            elif phase >= 2:
                self.down.discard(finger)
            self.most = max(self.most, len(self.down))
        return landed


def report(width, height, ifi, times, dropped, touches, why, timing):
    """Print what a run did, from the times its frames were shown, and return it."""
    actual = np.asarray(timing['actualTimestamp'], dtype=float)[-len(times):] if times else np.array([])
    status = np.asarray(timing['actualStatus'])[-len(times):] if times else np.array([])
    valid = (status == 0) & np.isfinite(actual)
    adjacent = valid[:-1] & valid[1:]
    intervals = np.diff(actual)[adjacent]
    confirmed = actual[valid]
    r = dict(window=f'{width:.0f} x {height:.0f} pixels', nominal_hz=1 / ifi, frames=len(times),
             seconds=float(confirmed[-1] - confirmed[0]) if len(confirmed)>1 else 0.0,
             confirmed_frames=int(valid.sum()), unconfirmed_frames=int(len(times)-valid.sum()),
             mean_hz=float(1 / intervals.mean()) if len(intervals) else float('nan'),
             longest_ms=float(1000 * intervals.max()) if len(intervals) else float('nan'),
             dropped_frames=int(dropped), touch_events=touches.count, most_fingers=touches.most, ended_by=why)
    print(f"Window: {r['window']}, nominally {r['nominal_hz']:.0f} Hz")
    print(f"{r['frames']} frames in {r['seconds']:.2f} s: {r['mean_hz']:.2f} per second")
    print(f"Longest gap between frames: {r['longest_ms']:.1f} ms")
    print(f"Frames the display reported never shown: {r['dropped_frames']}")
    print(f"Touch events: {r['touch_events']}, most fingers at once: {r['most_fingers']}")
    print(f"Ended by: {r['ended_by']}")
    return r



def main():
    parser = argparse.ArgumentParser(description='A hidden ring in noise, revealed by motion.')
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('--speed', type=int, default=1, help='pixels the noise drifts per frame (0 is still); default 1')
    parser.add_argument('--cell', type=int, default=1, help='noise cell width in pixels; default 1')
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(hidden_ring_demo, args.seconds, args.speed, args.cell, threaded=args.threaded)


if __name__ == '__main__':
    main()
