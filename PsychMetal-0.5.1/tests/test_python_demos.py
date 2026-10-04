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
check(not failures and report['checks'] == 15, 'readback_test: every frame reads back as drawn\n  ' + '\n  '.join(failures))

report, text = run(open_ready_test.open_ready_test, 4)
check(report['complete'] and all(r['ok'] for r in report['runs']) and
      [r['mode'] for r in report['runs']] == ['immediate', 'scheduled'] * 2,
      'open_ready_test: four opens, immediate and scheduled, all pass')

print(f'PASS: {passed} checks of the Python demos and hardware checks against the scripted engine.')
