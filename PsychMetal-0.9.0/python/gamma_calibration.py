#!/usr/bin/env python3
"""Measure the display's gamma by eye, as well as an eye can.

Python port of PsychMetalGammaCalibration.m:

    python3 gamma_calibration.py
    python3 gamma_calibration.py --channels rgb --repeats 3

A pattern whose pixels are half one grey and half another emits the mean of
their light, whatever the display's gamma. You adjust a uniform square inside
such a pattern until the two match, and the square's grey is then known to
emit that light. Nothing else is assumed, and no instrument is used.

  1. Half of white, twice: against black and white rows four pixels thick,
     and against columns. Rows and columns that agree are evidence that the
     display shows such a pattern at its mean light; their mean is taken as
     half of white.
  2. A quarter and three quarters. Stripes of black and the half grey are a
     quarter of white, and stripes of the half grey and white three quarters.
  3. The fit. The three matches are compared with a power law (its best
     gamma), with gamma 2.2 and with the sRGB curve, each by how many grey
     levels it misses them. The report also holds a table that follows the
     measured points, for pm.linearize(w, table).
  4. A check. With that table in use, a square at half is shown inside black
     and white stripes. They should now match, and you say whether they do.

That is four matches and a question: a minute or two. --full is the long form,
about ten minutes: half of white against nine patterns (rows and columns 1, 2,
4 and 8 pixels thick and a one-pixel checkerboard), which shows whether fine
patterns are at their mean light, then seven levels from an eighth to seven
eighths of white, every match made twice. Coarse patterns need distance.

The grey's number is not shown while you match, so it cannot guide you.

Keys: each tap of Up or Down changes the grey by one, of Right or Left by
eight; a key held down counts once. Space
accepts. Escape stops, and what was measured so far is reported. A mouse click
skips a match.

This is a calibration by eye. It finds the grey that matches a known fraction
of white to about one grey level; it cannot measure the light itself, and
below the darkest level matched it measures nothing. For work that depends on
luminance, use a photometer.

SPDX-License-Identifier: MIT
"""
import argparse
import math
import random

import numpy as np

import psychmetal as pm

PATTERNS = ('rows1', 'rows2', 'rows4', 'rows8', 'cols1', 'cols2', 'cols4', 'cols8', 'check1')
PATTERN_NAMES = dict(check1='checkerboard of single pixels')
for _kind, _word in (('rows', 'rows'), ('cols', 'columns')):
    for _t in (1, 2, 4, 8):
        PATTERN_NAMES[f'{_kind}{_t}'] = f"{_word} {_t} pixel{'s' if _t > 1 else ''} thick"
CHANNELS = dict(grey=(1, 1, 1), red=(1, 0, 0), green=(0, 1, 0), blue=(0, 0, 1))
KEYS = {name: pm.kb_name(name) for name in
        ('y', 'n', 'space', 'UpArrow', 'DownArrow', 'LeftArrow', 'RightArrow', 'ESCAPE')}
SETTLE = 30          # frames before a screen takes an answer, so one press cannot answer two
NOMINAL = 2.2        # used only to choose starting greys and for corrections of under half a grey level


class Stopped(Exception):
    pass


def pattern_image(side, pattern, low, high, mask=(1, 1, 1)):
    """side x side uint8, half its pixels low and half high; side is a multiple of 16."""
    if pattern not in PATTERNS:
        raise ValueError(f'Unknown pattern {pattern!r}; one of {", ".join(PATTERNS)}.')
    band = np.arange(side) // int(pattern[-1]) % 2 == 0
    if pattern.startswith('rows'):
        on = np.repeat(band[:, None], side, axis=1)
    elif pattern.startswith('cols'):
        on = np.repeat(band[None, :], side, axis=0)
    else:
        on = band[:, None] == band[None, :]
    grey = np.where(on, high, low).astype(np.uint8)
    if tuple(mask) == (1, 1, 1):
        return grey
    image = np.zeros((side, side, 3), dtype=np.uint8)
    for c in range(3):
        if mask[c]:
            image[:, :, c] = grey
    return image


def srgb_grey(light):
    """The grey, 0-255, at which the sRGB curve emits this fraction of white."""
    light = np.asarray(light, dtype=float)
    return 255 * np.where(light <= 0.0031308, 12.92 * light, 1.055 * np.power(light, 1 / 2.4) - 0.055)


def analyse(points, table_size=256):
    """Fit matched points [(grey, light), ...], light a fraction of white strictly between 0 and 1.

    Returns a dict: gamma, the power law that best fits them (least squares in log light); rmsPower,
    rmsGamma22 and rmsSRGB, how far each curve's predicted greys are from the matched ones, in grey
    levels rms; and table, table_size display values 0-1 for evenly spaced linear values, which
    follows the points with a power law between each pair and continues the darkest one to black."""
    points = sorted(points)
    grey = np.array([p[0] for p in points], dtype=float)
    light = np.array([p[1] for p in points], dtype=float)
    lg, ll = np.log(grey / 255), np.log(light)
    gamma = float(np.sum(ll * lg) / np.sum(lg * lg))
    rms = lambda predicted: float(np.sqrt(np.mean((predicted - grey) ** 2)))
    # The table: log grey against log light is a straight line for a power law, so interpolate there.
    x = np.append(ll, 0.0)
    y = np.append(lg, 0.0)
    linear = np.arange(table_size) / (table_size - 1)
    table = np.zeros(table_size)
    positive = linear > 0
    lx = np.log(linear[positive])
    slope = (y[1] - y[0]) / (x[1] - x[0])
    table[positive] = np.exp(np.where(lx < x[0], y[0] + (lx - x[0]) * slope, np.interp(lx, x, y)))
    return dict(gamma=gamma, rmsPower=rms(255 * light ** (1 / gamma)), rmsGamma22=rms(255 * light ** (1 / 2.2)),
                rmsSRGB=rms(srgb_grey(light)), table=np.clip(table, 0, 1))


def plan(levels):
    """(target light, lower target, upper target), in an order that defines each before it is used."""
    steps = [(0.5, 0.0, 1.0), (0.25, 0.0, 0.5), (0.75, 0.5, 1.0)]
    if levels == 7:
        steps += [(0.125, 0.0, 0.25), (0.375, 0.25, 0.5), (0.625, 0.5, 0.75), (0.875, 0.75, 1.0)]
    return steps


def synthetic_observer(curve):
    """An observer who matches exactly on a display whose light is curve(grey / 255): for tests."""
    def observe(low, high, mask, pattern, start, label):
        target = (curve(low / 255) + curve(high / 255)) / 2
        return min(range(256), key=lambda g: abs(curve(g / 255) - target))
    return observe


def gamma_calibration(repeats=1, levels=3, channels='grey', pattern='rows4', check=True, seed=None, observer=None,
                      patterns=None):
    """Run the calibration and return its report (a dict); see the module's description.

    channels is 'grey' or 'rgb' (red, green and blue each measured on its own). pattern is the one
    the curve is measured with. patterns are those half of white is matched against first: by default
    that one and its other orientation, and PATTERNS for all nine; check=False leaves that out. observer replaces
    the person, for tests: a function of (low, high, mask, pattern, start, label) returning a grey."""
    if levels not in (3, 7):
        raise ValueError('levels is 3 or 7.')
    if channels not in ('grey', 'rgb'):
        raise ValueError("channels is 'grey' or 'rgb'.")
    if pattern not in PATTERNS:
        raise ValueError(f'pattern is one of {", ".join(PATTERNS)}.')
    if not (isinstance(repeats, int) and 1 <= repeats <= 10):
        raise ValueError('repeats is 1 to 10.')
    partner = {'rows': 'cols', 'cols': 'rows'}.get(pattern[:4])
    partner = partner and partner + pattern[4:]
    if patterns is None:
        patterns = (pattern, partner) if partner else (pattern,)
    patterns = tuple(patterns) if check else ()
    if any(name not in PATTERNS for name in patterns):
        raise ValueError(f'patterns are among {", ".join(PATTERNS)}.')
    names = ['grey'] if channels == 'grey' else ['red', 'green', 'blue']
    rng = random.Random(seed)
    report = dict(pattern=pattern, repeats=repeats, levels=levels, matches=[], patternCheck=[], curves={},
                  gamma=None, table=None, verified=None, complete=False)
    w, rect, ifi = pm.open_window(None, 0)
    try:
        pm.hide_cursor()
        W, H = rect[2], rect[3]
        side = 16 * math.floor(min(W, H) * 0.0375)
        left, top = math.floor((W - side) / 2), math.floor(H * 0.26)
        outer = [left, top, left + side, top + side]
        inner = [left + side // 4, top + side // 4, left + 3 * side // 4, top + 3 * side // 4]
        size = max(12, math.floor(H / 50))
        held = set()
        todo = len(patterns) * repeats + len(names) * levels * repeats
        if pattern in patterns and 'grey' in names:
            todo -= repeats                  # half of white in the curve's pattern is matched once, not twice
        count = [0]

        def screen(lines, draw, answers, adjust=None):
            """Draw until an answer key is pressed and return its name; None on a mouse click."""
            frame = 0
            while True:
                draw()
                for i, line in enumerate(lines):
                    pm.draw_text(w, line, math.floor(W * 0.04), math.floor(H * 0.02 + i * size * 1.35), 220, size)
                pm.flip(w)
                frame += 1
                _, _, code = pm.kb_check()
                down = {name for name, index in KEYS.items() if code[index]}
                fresh = down - held
                held.clear()
                held.update(down)
                if 'ESCAPE' in down:
                    raise Stopped
                for name in down & set(adjust or ()):
                    if name in fresh:              # one step per press: a held key does not repeat
                        adjust[name]()
                if frame <= SETTLE:
                    continue
                for name in answers:
                    if name in fresh:
                        return name
                if pm.get_mouse(w)[2].any():
                    return None

        def by_eye(low, high, mask, pattern, start, label):
            texture = pm.make_texture(w, pattern_image(side, pattern, low, high, mask))
            grey = dict(level=start)

            def step(by):
                grey['level'] = min(255, max(0, grey['level'] + by))

            def draw():
                pm.draw_texture(w, texture, None, outer, 0, 0)
                pm.fill_rect(w, [grey['level'] * m for m in mask], inner)

            lines = [f'{label} The pattern is {PATTERN_NAMES[pattern]}.',
                     'Step back, or defocus, until the pattern blurs to a uniform field.',
                     'Make the square in the middle match it: as bright, no brighter. Judge the areas, not the edge.',
                     'Each tap of Up or Down changes the square by one level, of Right or Left by eight; holding does no more. Space accepts.']
            try:
                answer = screen(lines, draw, ('space',), dict(UpArrow=lambda: step(1), DownArrow=lambda: step(-1),
                                                               RightArrow=lambda: step(8), LeftArrow=lambda: step(-8)))
            finally:
                pm.close_texture(w, texture)
            return None if answer is None else grey['level']

        observe = observer or by_eye
        cache = {}

        def match(channel, pattern, low, high, light, stage):
            """Matches of this pattern, each from a new starting grey: [greys], possibly empty."""
            key = (channel, pattern, low, high)
            if key in cache:
                return cache[key]
            expected = 255 * light ** (1 / NOMINAL)
            values = []
            for r in range(repeats):
                count[0] += 1
                offset = rng.uniform(8, 20) * rng.choice((1, -1))
                start = int(min(254, max(1, round(expected + offset))))
                label = f'Match {count[0]} of {todo}, {channel}.'
                got = observe(low, high, CHANNELS[channel], pattern, start, label)
                if got is None:
                    break
                values.append(int(got))
                report['matches'].append(dict(stage=stage, channel=channel, pattern=pattern, low=low, high=high,
                                              light=light, start=start, matched=int(got)))
            cache[key] = values
            return values

        # ---- 1. half of white, by pattern ---------------------------------------------------
        for name in patterns:
            if True:
                values = match('grey', name, 0, 255, 0.5, 'patterns')
                if values:
                    report['patternCheck'].append(dict(pattern=name, matches=values, mean=float(np.mean(values))))

        # ---- 2. the curve, by halving -------------------------------------------------------
        for channel in names:
            # target light -> (the grey shown for it, the light that grey emits)
            known = {0.0: (0, 0.0), 1.0: (255, 1.0)}
            points = []
            for target, lower, upper in plan(levels):
                if lower not in known or upper not in known:
                    continue
                (low, low_light), (high, high_light) = known[lower], known[upper]
                light = (low_light + high_light) / 2
                values = match(channel, pattern, low, high, light, 'curve')
                if target == 0.5 and channel == 'grey' and partner in patterns:
                    # Half of white was also matched against the other orientation: use both.
                    values = values + cache.get(('grey', partner, 0, 255), [])
                if not values:
                    continue
                mean = float(np.mean(values))
                shown = int(round(mean))
                # The grey shown later is a whole number; its light differs from the match's by this much.
                known[target] = (shown, light * (shown / mean) ** NOMINAL)
                points.append(dict(light=light, grey=mean, matches=values))
            if points:
                fit = analyse([(p['grey'], p['light']) for p in points])
                report['curves'][channel] = dict(points=sorted(points, key=lambda p: p['light']), **fit)
        if len(report['curves']) == len(names):
            report['gamma'] = [report['curves'][c]['gamma'] for c in names]
            columns = [report['curves'][c]['table'] for c in names]
            report['table'] = np.stack(columns * 3 if len(columns) == 1 else columns, axis=1)
            report['complete'] = all(len(report['curves'][c]['points']) == levels for c in names)

        # ---- 4. the check: with the table in use, half is half ------------------------------
        if report['table'] is not None and observer is None:
            pm.linearize(w, report['table'])
            texture = pm.make_texture(w, pattern_image(side, pattern, 0, 255))
            try:
                answer = screen(['Check. The table just measured is in use, so the square is set to half of white.',
                                 f'The pattern is {PATTERN_NAMES[pattern]}, black and white: also half of white.',
                                 'Step back, or defocus, until the pattern blurs.',
                                 'Does the square match the pattern?   Y yes   N no'],
                                lambda: (pm.draw_texture(w, texture, None, outer, 0, 0), pm.fill_rect(w, 127.5, inner)),
                                ('y', 'n'))
            finally:
                pm.close_texture(w, texture)
                pm.linearize(w, None)
            report['verified'] = None if answer is None else answer == 'y'
    except Stopped:
        pass
    finally:
        pm.show_cursor()
        pm.close(w)
    print_report(report)
    return report


def print_report(report):
    print('\n===== gamma =====')
    listed = lambda values: ', '.join(str(v) for v in values)
    if report['patternCheck']:
        print('Half of white, by pattern: the grey that matched black and white.')
        for row in report['patternCheck']:
            print(f"  {PATTERN_NAMES[row['pattern']]:<30} {row['mean']:6.1f}   ({listed(row['matches'])})")
        means = {row['pattern']: row['mean'] for row in report['patternCheck']}
        within = [abs(x - y) for row in report['patternCheck'] for i, x in enumerate(row['matches']) for y in row['matches'][i + 1:]]
        typical = float(np.mean(within)) if within else 0.0
        tolerance = max(2.0, 1.5 * typical)
        thickest = lambda kind: max((name for name in means if name.startswith(kind)), key=lambda name: name[-1], default=None)
        rows, cols = thickest('rows'), thickest('cols')
        if rows and cols:
            coarse = (means[rows] + means[cols]) / 2
            others = [name for name in means if name not in (rows, cols)]
            if abs(means[rows] - means[cols]) > tolerance:
                print(f'  Rows and columns differ ({means[rows]:.1f} and {means[cols]:.1f}). Neither can be trusted to be half of white.')
                print('  Treat what follows as approximate, and measure with a photometer.')
            else:
                print(f'  Rows and columns agree ({means[rows]:.1f} and {means[cols]:.1f}): half of white is grey {coarse:.1f}, a gamma of '
                      f'{math.log(0.5) / math.log(coarse / 255):.2f} at that point.')
                if others:
                    furthest = max(others, key=lambda name: abs(means[name] - coarse))
                    if abs(means[furthest] - coarse) <= tolerance:
                        print('  The finer patterns agree with them: fine detail is shown at its mean light.')
                    else:
                        print(f'  Finer patterns are up to {abs(means[furthest] - coarse):.1f} grey levels from it ({PATTERN_NAMES[furthest]}: '
                              f'{means[furthest]:.1f}):')
                        print('  this display does not show all fine detail at its mean light.')
        elif len(means) > 1:
            print(f'  The patterns matched differ by {max(means.values()) - min(means.values()):.1f} grey levels.')
    if not report['curves']:
        print('Curve: not measured.')
        return
    print(f"The curve, measured with {PATTERN_NAMES[report['pattern']]}:")
    groups = {}
    for m in report['matches']:
        groups.setdefault((m['channel'], m['pattern'], m['low'], m['high']), []).append(m['matched'])
    differences = [abs(a - b) for values in groups.values() for i, a in enumerate(values) for b in values[i + 1:]]
    for channel, curve in report['curves'].items():
        print(f'  {channel}:  light   grey   matches')
        for p in curve['points']:
            print(f"         {p['light']:6.3f}  {p['grey']:5.1f}   ({listed(p['matches'])})")
        print(f"    Best power law: gamma {curve['gamma']:.2f}, which misses the matches by {curve['rmsPower']:.1f} grey levels rms.")
        print(f"    Gamma 2.2 misses them by {curve['rmsGamma22']:.1f}, and the sRGB curve by {curve['rmsSRGB']:.1f}.")
    if differences:
        print(f'Repeated matches of the same pattern differed by {np.mean(differences):.1f} grey levels on average, '
              f'{max(differences)} at most.')
    if report['table'] is None:
        print('Not every channel was measured, so there is no table.')
        return
    if not report['complete']:
        print('Some levels were skipped; the table follows the ones that were matched.')
    darkest = min(p['light'] for c in report['curves'].values() for p in c['points'])
    print(f"report['table'] follows the measured points: pm.linearize(w, report['table']). Below {darkest:g} of white")
    print('nothing was measured, and the table continues the darkest measured part of the curve.')
    if report['verified'] is not None:
        print(f"Check, with the table in use: half matched black and white stripes: {'yes' if report['verified'] else 'no'}.")
        if not report['verified']:
            print('  If the areas differed, the table does not make half of white half the light: do not use it.')
            print('  If only an edge showed, the areas may match; an edge is not evidence either way.')
    print('Measured by eye. A photometer measures light; this finds greys that match.')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--full', action='store_true', help='the long form: nine patterns, seven levels, each match twice')
    parser.add_argument('--repeats', type=int, help='matches of each pattern (default 1; 2 with --full)')
    parser.add_argument('--levels', type=int, choices=(3, 7), help='levels of the curve (default 3; 7 with --full)')
    parser.add_argument('--channels', default='grey', choices=('grey', 'rgb'), help='grey, or red, green and blue each')
    parser.add_argument('--pattern', choices=PATTERNS, help='the pattern the curve is measured with (default rows4; rows8 with --full)')
    parser.add_argument('--no-check', action='store_true', help='leave out the comparison of patterns')
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    repeats = args.repeats or (2 if args.full else 1)
    levels = args.levels or (7 if args.full else 3)
    pattern = args.pattern or ('rows8' if args.full else 'rows4')
    pm.run(gamma_calibration, repeats, levels, args.channels, pattern, not args.no_check, None, None,
           PATTERNS if args.full else None, threaded=args.threaded)


if __name__ == '__main__':
    main()
