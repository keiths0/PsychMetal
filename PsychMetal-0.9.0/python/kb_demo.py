#!/usr/bin/env python3
"""An on-screen keyboard that lights up as you type.

Python port of PsychMetalKbDemo.m:

    python3 kb_demo.py                 # 120 seconds
    python3 kb_demo.py 30

Draws a schematic keyboard with fill_rect and lights each key while it is held,
polling kb_check once per refresh. Press ESCAPE, or any mouse button, to leave.

This is also the instrument that verifies the keyboard path. The chain from a
physical key to a name has two hand-written tables: virtual keycode to HID
usage in the engine, and usage to name in the front end. Press a key and the
rectangle in that physical position should light, and the readout underneath
should name that key. If the wrong rectangle lights, the first table is wrong;
if the right one lights and the readout names something else, the second is.

Worth pressing deliberately: left and right shift (they must light
SEPARATELY; the same for control, option and command), an external keyboard,
and several keys at once (the ceiling is the keyboard's own).

The layout below is written in HID usages, the numbers the engine's table
uses; Python's key indices are the usage minus one, so key_code[usage - 1].

Text is drawn from the 5x7 bitmap font at the bottom of this file, because
PsychMetal has no text drawing.

SPDX-License-Identifier: MIT
"""
import argparse

import numpy as np

import psychmetal as pm


def kb_demo(seconds=120):
    w, rect, _ = pm.open_window(None, 18)
    try:
        pm.hide_cursor()
        keys = keyboard_layout()
        index = np.array([k['usage'] for k in keys]) - 1       # HID usage -> 0-based key index

        # Fit the layout to the window, preserving the aspect of a key.
        span_x = max(k['x'] + k['w'] for k in keys)
        span_y = max(k['y'] + k['h'] for k in keys)
        width, height = rect[2] - rect[0], rect[3] - rect[1]
        # Two thirds of the height for the keyboard, the rest for the readout.
        unit = min(width * 0.92 / span_x, height * 0.62 / span_y)
        origin_x = rect[0] + (width - unit * span_x) / 2
        origin_y = rect[1] + height * 0.14
        gap = unit * 0.06        # the gutter between keycaps

        # Key rectangles (4xN), computed once. Only the colours change per frame.
        bodies = np.array([[origin_x + k['x'] * unit + gap, origin_y + k['y'] * unit + gap,
                            origin_x + (k['x'] + k['w']) * unit - gap, origin_y + (k['y'] + k['h']) * unit - gap]
                           for k in keys]).T
        # Labels, also computed once, sized per key so a letter is large and RSHIFT still fits.
        label_rects = [layout_label(k['label'], bodies[:, j]) for j, k in enumerate(keys)]
        glyphs = np.hstack(label_rects)
        glyph_owner = np.concatenate([np.full(r.shape[1], j) for j, r in enumerate(label_rects)])

        up_colour = np.array([46, 48, 56])
        down_colour = np.array([245, 205, 90])
        edge_colour = [88, 90, 104]
        text_up = np.array([205, 208, 220])
        text_down = np.array([24, 22, 18])
        readout_colour = [235, 238, 248]
        readout_y = origin_y + span_y * unit + unit * 0.55
        readout_px = max(2, round(unit / 9))

        pm.flip(w)
        deadline = pm.get_secs() + seconds
        escape = pm.kb_name('ESCAPE')
        while pm.get_secs() < deadline:
            _, _, key_code = pm.kb_check()
            if key_code[escape]:
                break
            _, _, buttons = pm.get_mouse(w)
            if buttons.any():
                break
            down = key_code[index]

            # Three batched calls for the whole keyboard: every rectangle goes to
            # the GPU as one instanced draw.
            colours = np.where(down, down_colour[:, None], up_colour[:, None])
            pm.fill_rect(w, colours, bodies)
            pm.frame_rect(w, edge_colour, bodies, max(1, round(unit / 40)))
            if glyphs.shape[1]:
                pm.fill_rect(w, np.where(down[glyph_owner], text_down[:, None], text_up[:, None]), glyphs)

            # The readout names what is down, using the same kb_name table a
            # script would. A key with no rectangle still appears here.
            readout = readout_text(key_code)
            readout_rects = glyph_rects(readout, rect[0] + (width - text_width(readout, readout_px)) / 2,
                                        readout_y, readout_px)
            if readout_rects.shape[1]:
                pm.fill_rect(w, readout_colour, readout_rects)
            # Unscheduled: this demo has nothing to say about presentation timing.
            pm.flip(w)
    finally:
        pm.show_cursor()
        pm.close(w)


def readout_text(key_code):
    names = pm.kb_name(key_code)
    if not names:
        return 'PRESS ESCAPE TO EXIT'
    if len(names) > 6:
        names = names[:6] + ['...']
    return ' '.join(names).upper()


def keyboard_layout():
    """Where each key sits, in key units, y downward, ANSI layout: the rectangle
    that lights should be under the finger that pressed it."""
    keys = []

    def add_key(usage, x, y, w, h, label):
        keys.append(dict(usage=usage, x=x, y=y, w=w, h=h, label=label))

    def add_row(y, x0, usages, w, labels):
        for k, (usage, label) in enumerate(zip(usages, labels)):
            add_key(usage, x0 + k * w, y, w, 1, label)

    add_row(0, 0, [41] + list(range(58, 70)), 1.15, ['ESC'] + [f'F{k}' for k in range(1, 13)])
    add_row(1, 0, [53] + list(range(30, 40)) + [45, 46], 1,
            ['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '='])
    add_row(1, 13, [42], 2, ['DEL'])
    add_row(2, 0, [43], 1.5, ['TAB'])
    add_row(2, 1.5, [20, 26, 8, 21, 23, 28, 24, 12, 18, 19], 1, list('QWERTYUIOP'))
    add_row(2, 11.5, [47, 48], 1, ['[', ']'])
    add_row(2, 13.5, [49], 1.5, ['\\'])
    add_row(3, 0, [57], 1.75, ['CAPS'])
    add_row(3, 1.75, [4, 22, 7, 9, 10, 11, 13, 14, 15], 1, list('ASDFGHJKL'))
    add_row(3, 10.75, [51, 52], 1, [';', "'"])
    add_row(3, 12.75, [40], 2.25, ['RETURN'])
    # The two shifts are separate entries on purpose. If they ever light together
    # from one press, the engine's sidedness correction has regressed.
    add_row(4, 0, [225], 2.25, ['LSHIFT'])
    add_row(4, 2.25, [29, 27, 6, 25, 5, 17, 16], 1, list('ZXCVBNM'))
    add_row(4, 9.25, [54, 55, 56], 1, [',', '.', '/'])
    add_row(4, 12.25, [229], 2.75, ['RSHIFT'])
    add_row(5, 0, [224], 1.25, ['LCTRL'])
    add_row(5, 1.25, [226], 1.25, ['LOPT'])
    add_row(5, 2.5, [227], 1.5, ['LCMD'])
    add_row(5, 4, [44], 6.25, ['SPACE'])
    add_row(5, 10.25, [231], 1.5, ['RCMD'])
    add_row(5, 11.75, [230], 1.25, ['ROPT'])
    add_row(5, 13, [228], 1.25, ['RCTRL'])
    # The arrow cluster, with the half-height up and down keys of a real board.
    add_key(80, 15.25, 5, 1, 1, 'LEFT')
    add_key(82, 16.25, 5, 1, 0.5, 'UP')
    add_key(81, 16.25, 5.5, 1, 0.5, 'DOWN')
    add_key(79, 17.25, 5, 1, 1, 'RIGHT')
    return keys


def layout_label(label, body):
    """Centre a label in a keycap at the largest size that fits it."""
    bw, bh = body[2] - body[0], body[3] - body[1]
    px = int(np.floor(min(bw * 0.72 / max(1, text_width(label, 1)), bh * 0.42 / 7)))
    if px < 1:
        return np.zeros((4, 0))
    return glyph_rects(label, body[0] + (bw - text_width(label, px)) / 2, body[1] + (bh - 7 * px) / 2, px)


def text_width(s, px):
    return (6 * len(s) - 1) * px      # 5 wide plus one column of space, less the last


def glyph_rects(s, x, y, px):
    """One rectangle per lit font pixel, 4xN. A screen of text is a few thousand
    rectangles and they all batch into one draw, so no texture is needed."""
    out = []
    for k, ch in enumerate(s.upper()):
        glyph = FONT.get(ch)
        if glyph is None:
            continue
        rows, cols = np.nonzero(glyph)
        left = x + k * 6 * px + cols * px
        top = y + rows * px
        out.append(np.vstack([left, top, left + px, top + px]))
    return np.hstack(out) if out else np.zeros((4, 0))


# A 5x7 bitmap font, one glyph per line so every letter can be checked by eye.
# Rows are separated by |. Only the characters the labels and readout need.
_FONT_SPEC = {
    'A': '.###.|#...#|#...#|#####|#...#|#...#|#...#',
    'B': '####.|#...#|#...#|####.|#...#|#...#|####.',
    'C': '.###.|#...#|#....|#....|#....|#...#|.###.',
    'D': '####.|#...#|#...#|#...#|#...#|#...#|####.',
    'E': '#####|#....|#....|####.|#....|#....|#####',
    'F': '#####|#....|#....|####.|#....|#....|#....',
    'G': '.###.|#...#|#....|#.###|#...#|#...#|.###.',
    'H': '#...#|#...#|#...#|#####|#...#|#...#|#...#',
    'I': '#####|..#..|..#..|..#..|..#..|..#..|#####',
    'J': '....#|....#|....#|....#|#...#|#...#|.###.',
    'K': '#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#',
    'L': '#....|#....|#....|#....|#....|#....|#####',
    'M': '#...#|##.##|#.#.#|#...#|#...#|#...#|#...#',
    'N': '#...#|##..#|#.#.#|#..##|#...#|#...#|#...#',
    'O': '.###.|#...#|#...#|#...#|#...#|#...#|.###.',
    'P': '####.|#...#|#...#|####.|#....|#....|#....',
    'Q': '.###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#',
    'R': '####.|#...#|#...#|####.|#.#..|#..#.|#...#',
    'S': '.###.|#...#|#....|.###.|....#|#...#|.###.',
    'T': '#####|..#..|..#..|..#..|..#..|..#..|..#..',
    'U': '#...#|#...#|#...#|#...#|#...#|#...#|.###.',
    'V': '#...#|#...#|#...#|#...#|#...#|.#.#.|..#..',
    'W': '#...#|#...#|#...#|#...#|#.#.#|##.##|#...#',
    'X': '#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#',
    'Y': '#...#|#...#|.#.#.|..#..|..#..|..#..|..#..',
    'Z': '#####|....#|...#.|..#..|.#...|#....|#####',
    '0': '.###.|#...#|#..##|#.#.#|##..#|#...#|.###.',
    '1': '..#..|.##..|..#..|..#..|..#..|..#..|.###.',
    '2': '.###.|#...#|....#|...#.|..#..|.#...|#####',
    '3': '#####|...#.|..##.|....#|....#|#...#|.###.',
    '4': '...#.|..##.|.#.#.|#..#.|#####|...#.|...#.',
    '5': '#####|#....|####.|....#|....#|#...#|.###.',
    '6': '..##.|.#...|#....|####.|#...#|#...#|.###.',
    '7': '#####|....#|...#.|..#..|.#...|.#...|.#...',
    '8': '.###.|#...#|#...#|.###.|#...#|#...#|.###.',
    '9': '.###.|#...#|#...#|.####|....#|...#.|.##..',
    '-': '.....|.....|.....|#####|.....|.....|.....',
    '=': '.....|.....|#####|.....|#####|.....|.....',
    '[': '..##.|..#..|..#..|..#..|..#..|..#..|..##.',
    ']': '.##..|..#..|..#..|..#..|..#..|..#..|.##..',
    '\\': '#....|#....|.#...|..#..|...#.|....#|....#',
    '/': '....#|....#|...#.|..#..|.#...|#....|#....',
    ';': '.....|..#..|.....|.....|..#..|..#..|.#...',
    "'": '..#..|..#..|.....|.....|.....|.....|.....',
    ',': '.....|.....|.....|.....|..#..|..#..|.#...',
    '.': '.....|.....|.....|.....|.....|..##.|..##.',
    '`': '.#...|..#..|.....|.....|.....|.....|.....',
}
FONT = {ch: np.array([[c == '#' for c in row] for row in spec.split('|')]) for ch, spec in _FONT_SPEC.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=120)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(kb_demo, args.seconds, threaded=args.threaded)


if __name__ == '__main__':
    main()
