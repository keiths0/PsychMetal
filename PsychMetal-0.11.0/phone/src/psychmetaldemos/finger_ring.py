"""A ring of rectangles that turns round the pointer: the mouse on a Mac, a
finger on a phone. The dot at the pointer brightens while button 1 is down: a
click on a Mac, a second finger on a phone. It ends after a fixed time or on
Escape: three fingers on a phone.

Nothing here asks which machine it is on. Places are fractions of the window.

On a Mac:   PYTHONPATH=../../python python3 -m psychmetaldemos.finger_ring    (from the src folder)
"""
import numpy as np

import psychmetal as pm
from hidden_ring_demo import Touches, report   # the package demo's, shared


def finger_ring(seconds=15.0):
    with pm.open_window(None, [38, 38, 51]) as (w, rect, ifi):
        width, height = float(rect[2]), float(rect[3])
        unit = min(width, height)
        radius, size = 0.25 * unit, 0.04 * unit
        angle = np.linspace(0, 2 * np.pi, 12, endpoint=False)
        colours = np.vstack([255 * (0.5 + 0.5 * np.cos(angle)), np.full(12, 64.0),
                             255 * (0.5 + 0.5 * np.sin(angle))])                    # 3 x 12, one column each
        pm.set_mouse(w, width / 2, height / 2)
        escape = pm.kb_name('ESCAPE')
        times, touches, why = [], Touches(), 'time'
        began = vbl = pm.flip(w)[0]
        while vbl - began < seconds:
            x, y, buttons = pm.get_mouse(w)
            turned = angle + 0.5 * (vbl - began)
            cx, cy = x + radius * np.cos(turned), y + radius * np.sin(turned)
            pm.fill_rect(w, colours, np.vstack([cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2]),
                         angle=np.degrees(turned))                 # each one turning to stay square to the ring
            pm.fill_oval(w, 255 if buttons[0] else 128, [x - size / 2, y - size / 2, x + size / 2, y + size / 2])
            pm.draw_text(w, f'{1 / ifi:.0f} Hz    {seconds - (vbl - began):.0f} s', None, 0.08 * height, 255,
                         0.035 * unit)
            vbl = pm.flip(w)[0]
            times.append(vbl)
            touches.read(w)
            if pm.kb_check()[2][escape]:
                why = 'Escape'
                break
        dropped = pm.flip_info(w)['droppedFrames']
        timing = pm.diagnostic(w)
    return report(width, height, ifi, times, dropped, touches, why, timing)


if __name__ == '__main__':
    pm.run(finger_ring)
