#!/usr/bin/env python3
"""Every kind of shape PsychMetal draws, in colour and in motion, one panel each.

    python3 shapes_demo.py             # 20 seconds
    python3 shapes_demo.py 60

MATLAB and Octave: PsychMetalShapesDemo(seconds).

Twelve panels, each labelled with the call that draws it: filled and framed
rectangles and ovals, filled and framed polygons (turning, which costs nothing
extra: polygons are drawn on the GPU), lines, dots, arcs and wedges, text, a
Gabor patch, and translucent ovals blending. The panels stack three across on a
screen held upright and four across on one held sideways.

Escape (three fingers on a phone) or a click ends it.

SPDX-License-Identifier: MIT
"""
import argparse
import sys

import numpy as np

import psychmetal as pm

PALETTE = np.array([[230, 75, 60], [240, 170, 50], [90, 190, 110],
                    [70, 150, 230], [150, 100, 220], [230, 100, 170]], float)


def rotation(points, angle, cx, cy):
    """points (N, 2) about the origin, turned by angle radians and moved to (cx, cy)."""
    c, s = np.cos(angle), np.sin(angle)
    return np.column_stack([cx + c * points[:, 0] - s * points[:, 1], cy + s * points[:, 0] + c * points[:, 1]])


def star(points, outer, inner):
    angle = np.arange(2 * points) * np.pi / points - np.pi / 2
    radius = np.where(np.arange(2 * points) % 2, inner, outer)
    return np.column_stack([radius * np.cos(angle), radius * np.sin(angle)])


def polygon(sides, radius):
    angle = np.arange(sides) * 2 * np.pi / sides - np.pi / 2
    return np.column_stack([radius * np.cos(angle), radius * np.sin(angle)])


def panels(w, t, words):
    """The twelve panels at time t: (label, draw), draw(cx, cy, r) drawing round
    (cx, cy) within radius r."""
    def fill_rect(cx, cy, r):
        rects = np.array([[cx - r, cy - .7 * r, cx + .2 * r, cy + .2 * r],
                          [cx - .5 * r, cy - .3 * r, cx + .6 * r, cy + .6 * r],
                          [cx - .1 * r, cy - r, cx + r, cy - .1 * r]]).T
        pm.fill_rect(w, PALETTE[:3].T, rects)

    def frame_rect(cx, cy, r):
        for k, pen in enumerate((1, 2, 4, 6)):
            s = r * (1 - .22 * k)
            pm.frame_rect(w, PALETTE[k + 1], [cx - s, cy - .75 * s, cx + s, cy + .75 * s], pen)

    def fill_oval(cx, cy, r):
        aspect = [(1, .45), (.45, 1), (.7, .7)]
        rects = np.array([[cx - a * r, cy - b * r, cx + a * r, cy + b * r] for a, b in aspect]).T
        pm.fill_oval(w, PALETTE[[3, 5, 1]].T, rects)

    def frame_oval(cx, cy, r):
        for k in range(5):
            a, b = r * (1 - .17 * k), r * (.6 - .1 * k) * (1 + .4 * np.sin(t + k))
            pm.frame_oval(w, PALETTE[k], [cx - a, cy - b, cx + a, cy + b], 3)

    def fill_poly(cx, cy, r):
        pm.fill_poly(w, PALETTE[1], rotation(star(5, r, .45 * r), .6 * t, cx, cy))

    def frame_poly(cx, cy, r):
        pm.frame_poly(w, PALETTE[2], rotation(polygon(6, r), -.4 * t, cx, cy), 6)
        pm.frame_poly(w, PALETTE[4], rotation(polygon(3, .5 * r), .8 * t, cx, cy), 3)

    def draw_lines(cx, cy, r):
        n = 12
        angle = t * .3 + np.arange(n) * np.pi / n
        ends = np.vstack([np.cos(angle), np.sin(angle)]) * r
        xy = np.repeat(ends, 2, axis=1) * np.tile([1, -1], n)         # each spoke through the centre
        pm.draw_lines(w, xy, 3, PALETTE[np.arange(n) % 6].T, [cx, cy])     # one colour per line

    def draw_dots(cx, cy, r):
        n = 18
        angle = -.5 * t + np.arange(n) * 2 * np.pi / n
        xy = np.vstack([np.cos(angle), np.sin(angle)]) * r * (.75 + .2 * np.sin(3 * angle))
        pm.draw_dots(w, xy, .22 * r, PALETTE[np.arange(n) % 6].T, [cx, cy], 2)

    def arcs(cx, cy, r):
        sweep = 180 * (1 + np.sin(t)) + 10                            # the wedge opens and closes
        pm.fill_arc(w, PALETTE[0], [cx - .6 * r, cy - .6 * r, cx + .6 * r, cy + .6 * r], 0, sweep)
        turn = np.degrees(t) % 360                                    # angles as Screen's: degrees, clockwise from the top
        pm.frame_arc(w, PALETTE[3], [cx - .95 * r, cy - .95 * r, cx + .95 * r, cy + .95 * r], turn, 270, 5)
        pm.draw_arc(w, PALETTE[2], [cx - .78 * r, cy - .78 * r, cx + .78 * r, cy + .78 * r], -turn, 200)

    def draw_text(cx, cy, r):
        for k, (word, size, width) in enumerate(words):                # measured to fit, centred
            pm.draw_text(w, word, cx - width / 2, cy - r + k * .65 * r, PALETTE[(k * 2 + int(t)) % 6], size)

    def draw_gabor(cx, cy, r):
        pm.draw_gabor(w, None, [cx - r, cy - r, cx + r, cy + r], .45, 4 / r, 30, 180 * t)

    def blending(cx, cy, r):
        centres = [(0, -.35), (-.3, .2), (.3, .2)]
        colours = np.array([[255, 60, 60, 150], [60, 255, 60, 150], [60, 90, 255, 150]], float)
        rects = np.array([[cx + a * r - .6 * r, cy + b * r - .6 * r, cx + a * r + .6 * r, cy + b * r + .6 * r]
                          for a, b in centres]).T
        pm.fill_oval(w, colours.T, rects)

    return [('fill_rect', fill_rect), ('frame_rect', frame_rect), ('fill_oval', fill_oval),
            ('frame_oval', frame_oval), ('fill_poly', fill_poly), ('frame_poly', frame_poly),
            ('draw_lines', draw_lines), ('draw_dots', draw_dots), ('fill_arc, frame_arc, draw_arc', arcs),
            ('draw_text', draw_text), ('draw_gabor', draw_gabor), ('alpha blending', blending)]


def shapes_demo(seconds=20):
    if not (np.isfinite(seconds) and seconds > 0):
        raise ValueError('seconds must be positive.')
    w, rect, ifi = pm.open_window(None)
    try:
        width, height = float(rect[2]), float(rect[3])
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
                left, top = (k % across) * cell_w, (k // across) * cell_h
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
