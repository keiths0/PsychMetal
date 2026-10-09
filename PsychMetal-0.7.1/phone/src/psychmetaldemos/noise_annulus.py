"""Grey noise with a ring of other noise in it, still or scrolling: the package's
stimulus demo (python/stimulus_demo.py) with a ring for its aperture.

The background is a fixed noise image in a centered square, with black outside.
The ring can move throughout the window, including the black margins. A ring holds a
second fixed noise image, which moves with the ring. The ring moves as the
pointer moves (the mouse on a Mac, a finger on a phone), by the same amount,
from wherever it is: a finger put down does not fetch it. A click (a second
finger, on a phone) or the space bar changes the ring to a drifting grating
and back. Escape (three fingers) ends it. Neither noise image is made or
uploaded: a noise value is computed on the GPU from the seed and the pixel's
place in the rectangle it is drawn in, so moving a rectangle moves its image.

scroll is how many pixels the background moves sideways on every frame: 0 is
still. A scrolling background carries the ring with it, at the same rate, and
the pointer's movement is added to that. The ring is then never drawn in the
same place on two frames running: where the pointer's movement would exactly
undo the scroll, the ring is drawn a step back, and is where the pointer has
it on the next frame. A ring that leaves one side comes in at the other.

grain is the width of a noise cell in pixels. The ring is made of whole cells
and is only ever a whole number of cells from the background's corner, so its
cells lie on the background's and its edge cuts none of them: with a grain of
3 it moves in steps of 3 pixels. With a hard edge and whole cells every pixel
shows one image or the other, so a ring that is not moving against the
background cannot be seen.

On a Mac:   python3 -m psychmetaldemos.noise_annulus    (from the src folder)
"""
import numpy as np

import psychmetal as pm

from .finger_ring import Touches, report


def noise_annulus(seconds=20.0, scroll=0, grain=1):
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


if __name__ == '__main__':
    pm.run(noise_annulus)
