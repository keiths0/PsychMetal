"""Reusable GPU carriers and apertures. Space switches grating/noise; click/Escape exits."""
import argparse
import sys
import numpy as np
import psychmetal as pm


def stimulus_demo(seconds=20):
    w, rect, _ = pm.open_window()
    try:
        width, height = rect[2], rect[3]
        side = min(width, height)
        noise_rect = [(width-side)/2, (height-side)/2, (width+side)/2, (height+side)/2]
        background = pm.make_stimulus('noise', colour=True, seed=13)
        noise = pm.make_stimulus('noise', colour=True, seed=37)
        grating = pm.make_stimulus('grating', frequency=.025, contrast=.9)
        # Upload this reusable smooth aperture ONCE. It can then be moved/resized
        # without regenerating either the mask or any noise image.
        y, x = np.mgrid[-1:1:128j, -1:1:128j]
        coverage = np.clip((1-np.sqrt(x*x+y*y))/.12, 0, 1).astype(np.float32)
        mask = pm.make_texture(w, coverage)
        pm.set_mouse(w, width/2, height/2)
        pm.hide_cursor()
        pm.kb_wait(True)
        begin = pm.get_secs()
        previous_space = False
        touch = sys.platform == "ios"
        show_noise = False
        print('A second finger switches grating/noise; three fingers exits.' if touch else
              'Space switches grating/noise. Mouse moves aperture. Click or Escape exits.')
        while pm.get_secs()-begin < seconds:
            x, y, buttons = pm.get_mouse(w)
            down, _, keys = pm.kb_check()
            if (not touch and any(buttons)) or (down and keys[pm.kb_name('ESCAPE')]):
                break
            space = bool(buttons[0]) if touch else bool(keys[pm.kb_name('space')])
            if space and not previous_space:
                show_noise = not show_noise
            previous_space = space
            t = pm.get_secs()-begin
            half = side/4
            x = np.clip(x, half, width-half)
            y = np.clip(y, half, height-half)
            dest = [x-half, y-half, x+half, y+half]
            pm.fill_rect(w, [0, 0, 0])
            pm.draw_stimulus(w, background, noise_rect)
            pm.draw_stimulus(w, noise if show_noise else grating, dest, mask,
                             phase=-180*t, orientation=30)
            pm.flip(w)
    finally:
        pm.show_cursor()
        pm.close(w)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=20)
    parser.add_argument('--threaded', action='store_true')
    args = parser.parse_args()
    pm.run(stimulus_demo, args.seconds, threaded=args.threaded)
