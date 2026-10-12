#!/usr/bin/env python3
"""Check what the display does to a frame after the GPU has handed it over.

Python port of PsychMetalDisplayTest.m:

    python3 display_test.py

get_image and readback_test establish the frame the GPU rendered. They cannot
see the cable or the panel, and both can change a picture. This test shows
three patterns that expose the common ways, asks what you see, and reports.

  1. The link. The DisplayPort link is read from the system, with the bit rate
     this window needs. A link that cannot carry the picture is compressed
     (Display Stream Compression), and compression is not always invisible.
  2. Compression. Static single-pixel noise, with a small patch whose noise is
     new on every frame. On an uncompressed link the static noise is static.
     On a compressed link, noise that changes takes bits from the noise coded
     with it, and static noise near the patch twinkles. Shown and asked twice,
     in colour and then in grey, because a link can alter one and not the other.
  3. Pixel response. A static noise field beside one that is new on every
     frame, with the same distribution of values. Their mean luminance should
     be equal. A panel whose pixels do not settle within a frame shows the
     changing field darker.
  4. Gamma. Single-pixel rows of black and white, which emit half of white's
     light whatever the display's gamma, around a uniform grey you adjust until
     the two match. The matching grey gives the gamma to pass to linearize.
     This is an estimate by eye, and no substitute for a photometer.

Keys: Y or N to answer, the arrow keys to adjust, Space to accept, Escape to
stop. A mouse click skips a pattern without an answer.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm

KEYS = {name: pm.kb_name(name) for name in ('y', 'n', 'p', 'space', 'UpArrow', 'DownArrow', 'ESCAPE')}
SETTLE = 30          # frames before a pattern takes an answer, so one press cannot answer two


class Stopped(Exception):
    pass


def run_pattern(w, lines, draw, answers, presses=None, holds=None):
    """Draw until an answer key is pressed and return its name; None on a mouse click.

    lines() gives the instructions, drawn above the pattern. presses maps keys to
    functions called once per press, and so does holds: a held key does not repeat."""
    rect = pm.rect(w)
    size = max(12, math.floor(rect[3] / 50))
    held, frame = set(), 0
    while True:
        draw(frame)
        for i, line in enumerate(lines()):
            pm.draw_text(w, line, math.floor(rect[2] * 0.04), math.floor(rect[3] * 0.02 + i * size * 1.35), 220, size)
        pm.flip(w)
        frame += 1
        _, _, code = pm.kb_check()
        down = {name for name, index in KEYS.items() if code[index]}
        fresh, held = down - held, down
        if 'ESCAPE' in down:
            raise Stopped
        for name in down & set(holds or ()):
            if name in fresh:
                holds[name]()
        if frame <= SETTLE:
            continue
        for name in fresh & set(presses or ()):
            presses[name]()
        for name in answers:
            if name in fresh:
                return name
        if pm.get_mouse(w)[2].any():
            return None


def display_test():
    report = dict(link=None, colourTwinkleSeen=None, greyTwinkleSeen=None, dimmingSeen=None, matchingGrey=None, gamma=None)
    w, rect, ifi = pm.open_window(None, 0)
    try:
        pm.hide_cursor()
        W, H = rect[2], rect[3]
        report['link'] = link = pm.link_info(w)

        # ---- 2. compression: static noise with a patch that changes ------------------------
        side = 2 * math.floor(min(W, H) * 0.35)
        left, top = math.floor((W - side) / 2), math.floor(H * 0.26)
        field = [left, top, left + side, top + side]
        q = side // 4
        patch = [field[2] - q - q // 2, top + q // 2, field[2] - q // 2, top + q // 2 + q]
        state = dict(patch=True)

        def toggle():
            state['patch'] = not state['patch']

        for name, chroma, key in (('colour', 'colour', 'colourTwinkleSeen'), ('grey', 'mono', 'greyTwinkleSeen')):
            state['patch'] = True

            def compression(frame):
                pm.draw_noise(w, field, 1, 'uniform', chroma)
                if state['patch']:
                    pm.draw_noise(w, patch, 2 + frame % 16000000, 'uniform', chroma)

            def compression_text():
                return [f'Compression, {name} noise. The noise is static, except in a square at its upper right, '
                        'which is new every frame.',
                        'Look at the static noise below and beside that square, or cover the square with your hand.',
                        f"P turns the changing square off and on, for comparison. Now: {'changing' if state['patch'] else 'off'}.",
                        f'Does the static {name} noise twinkle while the square is changing?   Y yes   N no']

            answer = run_pattern(w, compression_text, compression, ('y', 'n'), presses=dict(p=toggle))
            report[key] = None if answer is None else answer == 'y'

        # ---- 3. pixel response: static beside changing --------------------------------------
        side = 2 * math.floor(min(W, H) * 0.3)
        gap = side // 8
        top = math.floor(H * 0.26)
        a = [math.floor(W / 2) - gap // 2 - side, top, math.floor(W / 2) - gap // 2, top + side]
        b = [a[2] + gap, top, a[2] + gap + side, top + side]

        def response(frame):
            pm.draw_noise(w, a, 1, 'uniform', 'mono')
            pm.draw_noise(w, b, 2 + frame % 16000000, 'uniform', 'mono')

        def response_text():
            return ['Pixel response. The left field is static. The right field is new every frame.',
                    'Both have the same values in the same proportions, so they should be equally bright.',
                    'Step back, or defocus, until the noise blurs to grey.',
                    'Is the right field darker than the left?   Y yes   N no']

        answer = run_pattern(w, response_text, response, ('y', 'n'))
        report['dimmingSeen'] = None if answer is None else answer == 'y'

        # ---- 4. gamma: single-pixel rows against a uniform grey -------------------------------
        side = 2 * math.floor(min(W, H) * 0.3)
        left, top = math.floor((W - side) / 2), math.floor(H * 0.26)
        rows = np.zeros((side, 2), dtype=np.uint8)
        rows[::2] = 255
        stripes = pm.make_texture(w, rows)
        inner = [left + side // 4, top + side // 4, left + 3 * side // 4, top + 3 * side // 4]
        grey = dict(level=186)

        def step(by):
            grey['level'] = min(254, max(1, grey['level'] + by))

        def gamma_now():
            return math.log(0.5) / math.log(grey['level'] / 255)

        def match(frame):
            pm.draw_texture(w, stripes, None, [left, top, left + side, top + side], 0, 0)
            pm.fill_rect(w, grey['level'], inner)

        def match_text():
            return ['Gamma. The stripes are single rows of black and white: half the light of white.',
                    'Step back until the stripes blur, then make the square in the middle match them.',
                    'Each tap of Up or Down changes the grey by one level; holding does no more. Space accepts.',
                    f"Grey {grey['level']} of 255: gamma {gamma_now():.2f}."]

        answer = run_pattern(w, match_text, match, ('space',),
                             holds=dict(UpArrow=lambda: step(1), DownArrow=lambda: step(-1)))
        if answer is not None:
            report['matchingGrey'], report['gamma'] = grey['level'], gamma_now()
    except Stopped:
        pass
    finally:
        pm.show_cursor()
        pm.close(w)

    # ---- report ---------------------------------------------------------------------------------
    said = {True: 'yes', False: 'no', None: 'not answered'}
    print('\n===== display =====')
    if link is None or math.isnan(link['lanes']):
        print('Link: not identified (a built-in panel, HDMI, or a system this cannot read).')
    else:
        print(f"Link: {link['lanes']:g} lanes at {link['laneGbps']:g} Gbit/s carry {link['payloadGbps']:.1f} Gbit/s. "
              f"This window needs {link['pixelGbps']:.1f}.")
        print({1: 'The picture cannot fit: the link is compressed.',
               0: 'The picture fits with room for blanking: the link has no need to compress.'}.get(
                   link['compressed'], 'The picture fits only without much blanking: compression cannot be ruled out.'))
    print(f"Static colour noise twinkled beside changing noise: {said[report['colourTwinkleSeen']]}.")
    print(f"Static grey noise twinkled beside changing noise: {said[report['greyTwinkleSeen']]}.")
    if report['greyTwinkleSeen']:
        print('  The display link alters fine detail, grey as well as coloured. Single-pixel noise is not delivered')
        print('  as rendered: use larger elements or a lower resolution.')
    elif report['colourTwinkleSeen']:
        print('  The display link alters fine coloured detail. Single-pixel coloured noise is not delivered as')
        print('  rendered: use grey noise, larger elements or a lower resolution.')
    print(f"Changing noise was darker than static noise: {said[report['dimmingSeen']]}.")
    if report['dimmingSeen']:
        print('  The panel does not settle within a frame. A region that changes every frame is darker than its')
        print('  values say; compare it only with regions that change as often.')
    if report['gamma'] is None:
        print('Gamma: not estimated.')
    else:
        print(f"Gamma, by eye: {report['gamma']:.2f} (grey {report['matchingGrey']} matched half of white). "
              f"pm.linearize(w, {report['gamma']:.2f})")
        print('  uses it. This is one match of one pattern, and assumes a power law: gamma_calibration.py')
        print('  measures the curve. Measure with a photometer before relying on either.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(display_test, threaded=args.threaded)


if __name__ == '__main__':
    main()
