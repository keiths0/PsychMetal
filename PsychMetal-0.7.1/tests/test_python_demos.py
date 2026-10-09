#!/usr/bin/env python3
"""Every Python demo and hardware-check port, run end to end against the
scripted engine. Run by tests/test_frontends.py, which builds the extension
and puts the python/ folder on the path.

The scripted engine simulates one display (PM_MOCK_DISPLAY) and a mouse that
clicks after a given number of flips (PM_MOCK_MOUSE), which is how each
program's own click-to-stop ends it here. What this proves: each program runs
through the real Python front end, calls every command with arguments the
front end and engine accept, cleans up, and reports what it should. What it
cannot prove is anything about the picture; that is what the programs are for
on a Mac."""
import contextlib
import io
import os

import numpy as np

import psychmetal as pm

passed = 0


def check(cond, what):
    global passed
    if not cond:
        raise AssertionError(what)
    passed += 1


def run(fn, *args, display='640x400@240', click=-1, threaded=False):
    """Run one program quietly with the given display and click; return (result, printed text)."""
    os.environ['PM_MOCK_DISPLAY'] = display
    os.environ['PM_MOCK_MOUSE'] = f'{click},3,-2'
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = pm.run(fn, *args, threaded=threaded)
    check(pm._S is None, f'{fn.__name__} closed its window')
    return result, out.getvalue()


import blob_demo
import dot_demo
import gabor_demo
import kb_demo
import kb_queue_demo
import minimal_demo
import mouse_rect_demo
import noise_demo
import texture_demo

_, text = run(minimal_demo.minimal_demo, 0.1)
check('Shapes appended 48, encoded' in text, 'minimal_demo: two shapes per frame for 24 frames')

report, text = run(mouse_rect_demo.mouse_rect_demo, 5, click=30)
check(report['frames'] == 30 and report['confirmed'] == 30,
      f"mouse_rect_demo: stops at the click with every frame confirmed ({report['frames']})")
check(report['inputToPhotonsMedianMs'] > 0, 'mouse_rect_demo: mouse-to-presentation latency is positive')

report, text = run(texture_demo.texture_demo, 5, click=30, threaded=True)
check(report['texturesCreated'] == 2 and report['texturesDrawn'] == 5 * report['frames'],
      f"texture_demo (threaded): two uploads, five texture draws a frame ({report['texturesDrawn']:.0f})")

report, text = run(gabor_demo.gabor_demo, 5, 12, 2, 0.02, click=40)
check(report['frames'] == 40 and report['cols'] * report['rows'] >= 12, 'gabor_demo: grid holds every patch')
check(abs(report['phaseStepMedianDeg'] - report['phaseStepExpectedDeg']) < 0.01 * report['phaseStepExpectedDeg'],
      f"gabor_demo: phase advances with presented time ({report['phaseStepMedianDeg']:.3f} deg/frame)")
check(pm._core.diagnostic()[1]['shapesAppended'] >= 12 * 40, 'gabor_demo: one Gabor per patch per frame')
report, _ = run(gabor_demo.gabor_demo, 5, 1, 2, 0, click=10)
check(report['frames'] == 10 and report['cyclesAcrossPatch'] == 0, 'gabor_demo: one Gaussian at frequency 0')

report, text = run(noise_demo.noise_demo, 0.2, display='320x200@240')
check(report['frames'] == 48 and report['rebuildStable'] and len(set(report['modeOf'])) == 4,
      'noise_demo: cycles the four modes and rebuilds a frame deterministically')
check(np.unique(report['seeds']).size > 40, 'noise_demo: a fresh seed each frame')
check('RECONSTRUCTION' in text and 'Per mode:' in text, 'noise_demo: prints the reconstruction and per-mode rates')
report, _ = run(noise_demo.noise_demo, 0.05, 'normal', 'colour', 38, display='320x200@240')
check(report['modes'] == [('normal', 'colour')], 'noise_demo: a single requested mode')

report, text = run(blob_demo.blob_demo, 5, 2, 0.25, click=30)
check(report['frames'] == 30 and 0.25 <= report['luminanceMin'] <= report['luminanceMax'] <= 0.75,
      'blob_demo: luminance stays within the contrast about mid-grey')

for sprites in (0, 1, 2):
    run(dot_demo.dot_demo, sprites, 1, click=25)
    drawn = pm._core.diagnostic()[1]['texturesDrawn']
    if sprites:
        check(drawn > 0 and drawn % 400 == 0, f'dot_demo {sprites}: all 400 sprites every frame ({drawn:.0f})')
    else:
        check(drawn == 0, 'dot_demo 0: dots, no textures')

run(kb_demo.kb_demo, 0.2)
check(pm._core.diagnostic()[1]['shapesAppended'] > 0, 'kb_demo: draws the keyboard until its deadline')
check(kb_demo.glyph_rects('I', 0, 0, 1).shape == (4, 15), 'kb_demo: a glyph is one rectangle per lit pixel')
layout = kb_demo.keyboard_layout()
usages = [k['usage'] for k in layout]
check(len(layout) == 77 and len(set(usages)) == 77, 'kb_demo: 77 keys, each a different usage')
check(all(pm.kb_name(pm.kb_name(u - 1)) == u - 1 for u in usages),
      'kb_demo: every key in the layout has a name that maps back to the same key')
check(kb_demo.readout_text(np.zeros(256, bool)) == 'PRESS ESCAPE TO EXIT', 'kb_demo: the idle readout')

events, text = run(kb_queue_demo.kb_queue_demo, 0.6)
check(events.shape == (0, 3) and 'Tap T' in text, 'kb_queue_demo: queue created, polled and released')

# --- hardware-check ports --------------------------------------------------------------
import hardware_test
import inventory_test
import motion_test
import mouse_test
import open_ready_test
import readback_test

_, text = run(hardware_test.hardware_test)
check('PASS: texture snapshots' in text, 'hardware_test: lifecycle checks pass')

report, text = run(inventory_test.inventory_test, display='640x400@60')
failures = [r['name'] + ': ' + r['detail'] for r in report['results'] if not r['ok']]
check(not failures, 'inventory_test: every check passes, including coverage of every command\n  ' + '\n  '.join(failures))
check(report['commandsDeclared'] == len(pm.__all__) - 1, 'inventory_test: every public function counts as a command')

report, text = run(motion_test.motion_test, 64, 60)
check(report['complete'] and report['stats']['confirmed'] == 60,
      'motion_test: 60 measured frames, all confirmed')
check(os.path.exists(text.split('Saved ')[1].split('.txt')[0] + '.json'), 'motion_test: saves its report')

report, text = run(mouse_test.mouse_test, 0.3, None, click=10)
check(list(report['pressCounts']) == [1, 0, 0] and report['samples'] > 10,
      f"mouse_test: one left press counted ({list(report['pressCounts'])})")

report, text = run(readback_test.readback_test)
failures = [f"{r['name']}: {r['detail']}" for r in report['results'] if not r['ok']]
check(not failures and report['checks'] == 46, 'readback_test: every frame reads back as drawn\n  ' + '\n  '.join(failures))

import display_test

report, text = run(display_test.display_test, click=0)
check(report['colourTwinkleSeen'] is None and report['greyTwinkleSeen'] is None and report['dimmingSeen'] is None and report['gamma'] is None
      and 'Link: not identified' in text and text.count('not answered') == 3 and 'Gamma: not estimated.' in text,
      'display_test: every pattern is skipped by a click and the report says so')
check(pm._core.diagnostic()[0].shape[0] == 4 * (display_test.SETTLE + 1), 'display_test: each pattern takes no answer while it settles')
# Scripted keys, by HID usage and frame: P (19) toggles the patch; N (17) answers the colour pattern and is
# held into the grey one, where it must not count until pressed again; Y (28) answers the grey pattern and
# N the third; in the fourth Down (81) is held for 21 frames, which is one step, and tapped again, then Space (44) accepts.
os.environ['PM_MOCK_KEYS'] = '19:38-40,17:45-90,28:120-122,17:170-172,81:210-231,81:235-236,44:240-242'
report, text = run(display_test.display_test)
del os.environ['PM_MOCK_KEYS']
check(report['colourTwinkleSeen'] is False and report['greyTwinkleSeen'] is True and report['dimmingSeen'] is False,
      'display_test: colour and grey are asked separately, and answers are taken once per press')
check(report['matchingGrey'] == 184 and abs(report['gamma'] - np.log(0.5) / np.log(184 / 255)) < 1e-12
      and 'Gamma, by eye: 2.12 (grey 184 matched half of white)' in text and 'grey as well as coloured' in text,
      f"display_test: a held arrow is one step, a second tap another, and Space accepts ({report['matchingGrey']})")
os.environ['PM_MOCK_KEYS'] = '41:50-52'
report, text = run(display_test.display_test)
del os.environ['PM_MOCK_KEYS']
check(report['colourTwinkleSeen'] is None and pm._core.diagnostic()[0].shape[0] == 50, 'display_test: Escape stops it')
os.environ['PM_MOCK_LINK'] = '4,5.4'
report, text = run(display_test.display_test, display='6016x3384@60', click=0)
del os.environ['PM_MOCK_LINK']
check(report['link']['compressed'] == 1 and '4 lanes at 5.4 Gbit/s carry 17.3 Gbit/s. This window needs 29.3.' in text
      and 'the link is compressed' in text, 'display_test: reports a link that cannot carry the picture')

import gamma_calibration
ALL = gamma_calibration.PATTERNS

report, text = run(gamma_calibration.gamma_calibration, click=0)
check(not report['matches'] and report['table'] is None and 'Curve: not measured.' in text
      and pm._core.diagnostic()[0].shape[0] == 2 * (gamma_calibration.SETTLE + 1),
      'gamma_calibration: a click skips each pattern, and what depends on a skipped match is not shown')
# Observers who match exactly on displays of known curves: the calibration must recover the curves.
srgb = lambda v: v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
for name, curve, gamma in (('gamma 2.4', lambda v: v ** 2.4, 2.4), ('gamma 1.8', lambda v: v ** 1.8, 1.8), ('sRGB', srgb, None)):
    # The short form: half of white against rows and columns, a quarter, three quarters.
    report, text = run(gamma_calibration.gamma_calibration, 1, 3, 'grey', 'rows4', True, 1, gamma_calibration.synthetic_observer(curve))
    fit = report['curves']['grey']
    check(report['complete'] and len(report['matches']) == 4 and [m['pattern'] for m in report['matches']] == ['rows4', 'cols4', 'rows4', 'rows4']
          and report['table'].shape == (256, 3) and 'Rows and columns agree' in text and 'Repeated matches' not in text,
          f'gamma_calibration: {name}: the short form is four matches')
    worst = max(abs(curve(t) - k / 255) for k, t in enumerate(report['table'][:, 0]))
    check(worst < 0.02 and (gamma is None or abs(fit['gamma'] - gamma) < 0.02),
          f"gamma_calibration: {name}: the short form's table linearizes to within 2% of white ({worst:.4f}, gamma {fit['gamma']:.3f})")
    # The long form.
    report, text = run(gamma_calibration.gamma_calibration, 2, 7, 'grey', 'rows8', True, 1,
                       gamma_calibration.synthetic_observer(curve), ALL)
    fit = report['curves']['grey']
    table = report['table']
    check(report['complete'] and len(report['matches']) == 30 and table.shape == (256, 3) and (np.diff(table[:, 0]) > 0).all()
          and report['verified'] is None and 'The finer patterns agree with them' in text,
          f'gamma_calibration: {name}: the long form is 30 matches, a rising 256x3 table, and patterns that agree')
    worst = max(abs(curve(t) - k / 255) for k, t in enumerate(table[:, 0]))
    check(worst < 0.01, f'gamma_calibration: {name}: the table linearizes the display to within 1% of white ({worst:.4f})')
    if gamma:
        check(abs(fit['gamma'] - gamma) < 0.01 and fit['rmsPower'] < 0.5 and fit['rmsPower'] < fit['rmsSRGB'],
              f"gamma_calibration: {name} is recovered ({fit['gamma']:.3f})")
    else:
        check(fit['rmsSRGB'] < 0.5 and fit['rmsSRGB'] < fit['rmsPower'] and fit['rmsSRGB'] < fit['rmsGamma22'],
              f"gamma_calibration: the sRGB curve is told from a power law ({fit['rmsSRGB']:.2f} against {fit['rmsPower']:.2f})")
# A display whose single-pixel columns are 4% brighter than their mean, and one whose rows and columns differ.
ideal = lambda v: v ** 2.2
def uneven(gain):
    def observe(low, high, mask, pattern, start, label):
        light = (ideal(low / 255) + ideal(high / 255)) / 2 * gain.get(pattern, 1)
        return min(range(256), key=lambda g: abs(ideal(g / 255) - light))
    return observe
report, text = run(gamma_calibration.gamma_calibration, 1, 3, 'grey', 'rows8', True, 1, uneven(dict(cols1=1.04)), ALL)
check('Rows and columns agree (186.0 and 186.0)' in text and 'grey levels from it (columns 1 pixel thick: 189.0)' in text,
      'gamma_calibration: a fine pattern that is not at its mean light is reported, and the coarse ones are used')
report, text = run(gamma_calibration.gamma_calibration, 1, 3, 'grey', 'rows4', True, 1, uneven(dict(cols4=0.93)))
check('Rows and columns differ (186.0 and 180.0)' in text and report['curves']['grey']['points'][1]['matches'] == [186, 180],
      'gamma_calibration: rows and columns that differ are reported, and both are in the half-white point')
report, text = run(gamma_calibration.gamma_calibration, 1, 3, 'rgb', 'rows1', False, 1,
                   gamma_calibration.synthetic_observer(lambda v: v ** 2.0))
check(list(report['curves']) == ['red', 'green', 'blue'] and len(report['matches']) == 9 and not report['patternCheck']
      and all(abs(g - 2.0) < 0.02 for g in report['gamma']), 'gamma_calibration: red, green and blue each measured')
# By eye, with scripted keys: Down (81) is held (one step) and tapped again in the first match, then Space (44)
# accepts every 40 frames, and Y (28) answers the check.
os.environ['PM_MOCK_KEYS'] = ','.join(['81:32-38,81:41-43'] + [f'44:{45 + 40 * k}-{47 + 40 * k}' for k in range(4)] + ['28:205-207'])
report, text = run(gamma_calibration.gamma_calibration, 1, 3, 'grey', 'rows4', True, 5)
del os.environ['PM_MOCK_KEYS']
first = report['matches'][0]
check(len(report['matches']) == 4 and first['matched'] == first['start'] - 2 and report['verified'] is True
      and all(m['matched'] == m['start'] for m in report['matches'][1:]) and report['table'].shape == (256, 3)
      and 'half matched black and white stripes: yes' in text,
      'gamma_calibration: a held arrow is one step, a second tap another, Space accepts, and the check is answered')
starts = [m['start'] - 255 * m['light'] ** (1 / 2.2) for m in report['matches']]
check(all(7 <= abs(d) <= 21 for d in starts), 'gamma_calibration: no match starts at the expected grey')
os.environ['PM_MOCK_KEYS'] = '41:50-52'
report, text = run(gamma_calibration.gamma_calibration)
del os.environ['PM_MOCK_KEYS']
check(not report['matches'] and pm._core.diagnostic()[0].shape[0] == 50 and 'Curve: not measured.' in text,
      'gamma_calibration: Escape stops it')

report, text = run(open_ready_test.open_ready_test, 4)
check(report['complete'] and all(r['ok'] for r in report['runs']) and
      [r['mode'] for r in report['runs']] == ['immediate', 'scheduled'] * 2,
      'open_ready_test: four opens, immediate and scheduled, all pass')

print(f'PASS: {passed} checks of the Python demos and hardware checks against the scripted engine.')
