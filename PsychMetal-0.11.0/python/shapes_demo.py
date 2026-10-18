#!/usr/bin/env python3
"""Every kind of shape PsychMetal draws, in colour and in motion, one panel each.

    python3 shapes_demo.py             # 20 seconds
    python3 shapes_demo.py 60

MATLAB and Octave: PsychMetalShapesDemo(seconds).

Twelve panels, each labelled with the call that draws it: filled and framed
rectangles and ovals, filled and framed polygons, lines, dots, arcs and wedges,
text, a Gabor patch, and translucent ovals blending. Nearly everything turns:
by each command's angle (each rect, oval, arc and Gabor about its own centre,
the lines and dots about their centre, text about its top left), or by
translate, rotate and scale, which move, turn and scale whatever is
drawn between push_matrix and pop_matrix as one, as the polygons, the
blending ovals and two of the words are. Turning costs nothing extra: the GPU's
vertex shaders apply it. The panels stack three across on a screen held upright
and four across on one held sideways.

Escape (three fingers on a phone) or a click ends it.

SPDX-License-Identifier: MIT
"""
import argparse
import sys

import numpy as np

import psychmetal as pm
from audio_demo import safe_area

PALETTE = np.array([[230, 75, 60], [240, 170, 50], [90, 190, 110],
                    [70, 150, 230], [150, 100, 220], [230, 100, 170]], float)


def star(points, outer, inner):
    angle = np.arange(2 * points) * np.pi / points - np.pi / 2
    radius = np.where(np.arange(2 * points) % 2, inner, outer)
    return np.column_stack([radius * np.cos(angle), radius * np.sin(angle)])


def polygon(sides, radius):
    angle = np.arange(sides) * 2 * np.pi / sides - np.pi / 2
    return np.column_stack([radius * np.cos(angle), radius * np.sin(angle)])


class turned_about:
    """with turned_about(w, cx, cy, degrees[, scale]): what is drawn inside, about
    [0, 0], is scaled, turned and moved to (cx, cy), by the window's transform."""
    def __init__(self, w, cx, cy, degrees, scale=1.0):
        self.args = w, cx, cy, degrees, scale

    def __enter__(self):
        w, cx, cy, degrees, scale = self.args
        pm.push_matrix(w)
        pm.translate(w, cx, cy)
        pm.rotate(w, degrees)
        pm.scale(w, scale, scale)

    def __exit__(self, *exc):
        pm.pop_matrix(self.args[0])
        return False


def panels(w, t, words):
    """The twelve panels at time t: (label, draw), draw(cx, cy, r) drawing round
    (cx, cy) within radius r. Angles are degrees, clockwise; most things turn."""
    spin = np.degrees(t)                                          # one radian a second

    def fill_rect(cx, cy, r):
        rects = np.array([[cx - r, cy - .7 * r, cx + .2 * r, cy + .2 * r],
                          [cx - .5 * r, cy - .3 * r, cx + .6 * r, cy + .6 * r],
                          [cx - .1 * r, cy - r, cx + r, cy - .1 * r]]).T
        pm.fill_rect(w, PALETTE[:3].T, rects, angle=[.5 * spin, -.8 * spin, 0])   # each about its own centre

    def frame_rect(cx, cy, r):
        for k, pen in enumerate((1, 2, 4, 6)):
            s = r * (1 - .22 * k)
            pm.frame_rect(w, PALETTE[k + 1], [cx - s, cy - .55 * s, cx + s, cy + .55 * s], pen,
                          angle=(-1) ** k * .3 * (k + 1) * spin)

    def fill_oval(cx, cy, r):
        aspect = [(1, .45), (.45, 1), (.7, .7)]
        rects = np.array([[cx - a * r, cy - b * r, cx + a * r, cy + b * r] for a, b in aspect]).T
        pm.fill_oval(w, PALETTE[[3, 5, 1]].T, rects, angle=[.6 * spin, .6 * spin, 0])

    def frame_oval(cx, cy, r):
        for k in range(5):
            a, b = r * (1 - .17 * k), r * (.6 - .1 * k) * (1 + .4 * np.sin(t + k))
            pm.frame_oval(w, PALETTE[k], [cx - a, cy - b, cx + a, cy + b], 3, angle=15 * k * np.sin(.5 * t))

    def fill_poly(cx, cy, r):
        with turned_about(w, cx, cy, .6 * spin):                 # a star's own points, about [0 0]
            pm.fill_poly(w, PALETTE[1], star(5, r, .45 * r))

    def frame_poly(cx, cy, r):
        with turned_about(w, cx, cy, -.4 * spin):
            pm.frame_poly(w, PALETTE[2], polygon(6, r), 6)
        with turned_about(w, cx, cy, .8 * spin):
            pm.frame_poly(w, PALETTE[4], polygon(3, .5 * r), 3)

    def draw_lines(cx, cy, r):
        n = 12
        angle = np.arange(n) * np.pi / n
        ends = np.vstack([np.cos(angle), np.sin(angle)]) * r
        xy = np.repeat(ends, 2, axis=1) * np.tile([1, -1], n)         # each spoke through the centre
        pm.draw_lines(w, xy, 3, PALETTE[np.arange(n) % 6].T, [cx, cy], angle=.3 * spin)   # turned about center

    def draw_dots(cx, cy, r):
        n = 18
        angle = -.5 * t + np.arange(n) * 2 * np.pi / n                # the dots run along the three-lobed contour
        xy = np.vstack([np.cos(angle), np.sin(angle)]) * r * (.75 + .2 * np.sin(3 * angle))
        pm.draw_dots(w, xy, .22 * r, PALETTE[np.arange(n) % 6].T, [cx, cy], 2, angle=.2 * spin)   # and the contour turns

    def arcs(cx, cy, r):
        sweep = 180 * (1 + np.sin(t)) + 10                            # the wedge opens and closes
        pm.fill_arc(w, PALETTE[0], [cx - .6 * r, cy - .6 * r, cx + .6 * r, cy + .6 * r], 0, sweep)
        pm.frame_arc(w, PALETTE[3], [cx - .95 * r, cy - .95 * r, cx + .95 * r, cy + .95 * r], 0, 270, 5, angle=spin)
        pm.draw_arc(w, PALETTE[2], [cx - .78 * r, cy - .78 * r, cx + .78 * r, cy + .78 * r], 0, 200, angle=-spin)

    def draw_text(cx, cy, r):
        (big, big_size, big_w), (small, small_size, small_w), (aa, aa_size, aa_w) = words
        with turned_about(w, cx, cy - .45 * r, .5 * spin):          # spinning about its middle
            pm.draw_text(w, big, -big_w / 2, -big_size / 2, PALETTE[int(t) % 6], big_size)
        pm.draw_text(w, small, cx - small_w / 2, cy + .05 * r, PALETTE[(int(t) + 2) % 6], small_size,
                     angle=25 * np.sin(2 * t))                       # swinging about its top left
        with turned_about(w, cx, cy + .65 * r, 0, .75 + .35 * np.sin(1.5 * t)):   # growing and shrinking
            pm.draw_text(w, aa, -aa_w / 2, -aa_size / 2, PALETTE[(int(t) + 4) % 6], aa_size)

    def draw_gabor(cx, cy, r):
        g = 1.25 * r                    # a larger patch and a narrower envelope (sigma .3 of its half-size):
        pm.draw_gabor(w, None, [cx - g, cy - g, cx + g, cy + g], .3, 4 / r, 30, 180 * t,   # it fades out
                      rotation=.4 * spin)                     # before the patch's edge, with no square showing

    def blending(cx, cy, r):
        centres = [(0, -.35), (-.3, .2), (.3, .2)]
        colours = np.array([[255, 60, 60, 150], [60, 255, 60, 150], [60, 90, 255, 150]], float)
        rects = np.array([[a * r - .6 * r, b * r - .6 * r, a * r + .6 * r, b * r + .6 * r]
                          for a, b in centres]).T
        with turned_about(w, cx, cy, -.5 * spin):                    # the three as one group
            pm.fill_oval(w, colours.T, rects)

    return [('fill_rect', fill_rect), ('frame_rect', frame_rect), ('fill_oval', fill_oval),
            ('frame_oval', frame_oval), ('fill_poly, rotate', fill_poly), ('frame_poly, rotate', frame_poly),
            ('draw_lines', draw_lines), ('draw_dots', draw_dots), ('fill_arc, frame_arc, draw_arc', arcs),
            ('draw_text, rotate, scale', draw_text), ('draw_gabor', draw_gabor),
            ('alpha blending, rotate', blending)]


def shapes_demo(seconds=20):
    if not (np.isfinite(seconds) and seconds > 0):
        raise ValueError('seconds must be positive.')
    w, rect, ifi = pm.open_window(None)
    try:
        # The panels fill the safe area: on a phone, clear of the camera housing,
        # the rounded corners and the home indicator; on a Mac, the whole window.
        area = safe_area(w, rect)
        width, height = float(area[2] - area[0]), float(area[3] - area[1])
        across, down = (4, 3) if width >= height else (3, 4)
        cell_w, cell_h = width / across, height / down
        label = min(cell_w, cell_h) * .085
        radius = min(cell_w, cell_h - 2.2 * label) * .36
        # Text is measured once and made to fit: each label centred along the
        # bottom of its panel, the text panel's words within the panel's width.
        def fitted(text, size, room):
            width = pm.text_bounds(w, text, size)[0][2]
            if width > room:
                size *= room / width
                width = pm.text_bounds(w, text, size)[0][2]
            return size, width
        names = [name for name, _ in panels(w, 0, [])]
        labels = [fitted(name, label, cell_w - 16) for name in names]
        words = [(word, *fitted(word, size * radius, 2 * radius))
                 for word, size in (('Metal', .45), ('text', .3), ('Aa', .55))]
        pm.hide_cursor()
        escape = pm.kb_name('ESCAPE')
        touch = sys.platform == 'ios'
        frames, began = 0, pm.get_secs()
        vbl = began
        while vbl - began < seconds:
            _, _, buttons = pm.get_mouse(w)
            if pm.kb_check()[2][escape] or (not touch and any(buttons)):
                break
            t = vbl - began
            pm.fill_rect(w, [24, 26, 34])
            for k, (name, draw) in enumerate(panels(w, t, words)):
                left, top = area[0] + (k % across) * cell_w, area[1] + (k // across) * cell_h
                pm.fill_rect(w, [34, 37, 48], [left + 4, top + 4, left + cell_w - 4, top + cell_h - 4])
                draw(left + cell_w / 2, top + (cell_h - 1.6 * label) / 2 + 4, radius)
                size, width = labels[k]
                pm.draw_text(w, name, left + (cell_w - width) / 2, top + cell_h - 1.6 * label, [200, 205, 215], size)
            vbl = pm.flip(w)[0]
            frames += 1
        d = pm.diagnostic(w)
    finally:
        pm.show_cursor()
        pm.close(w)
    s = d['summary']
    print(f"{frames} frames of twelve panels; {s['shapesEncoded']:.0f} shapes encoded in all.")
    return dict(frames=frames)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(shapes_demo, args.seconds, threaded=args.threaded)


if __name__ == '__main__':
    main()
