#!/usr/bin/env python3
"""The phone app's list and its own demos (phone/), against the scripted engine.
Run by tests/test_frontends.py with the python/ folder and phone/src on the
path. The app's window is not made here: that needs Toga.

What this proves: everything the app lists can be imported and has the function
it names, the app is given every file it lists, and the demos made for fingers
run, keep the ring on the background's cells and never draw it still while the
background scrolls. Nothing here is a phone: fingers are tests/test_fingers.py."""
import contextlib
import importlib
import io
import os
import re
from pathlib import Path

import numpy as np

import psychmetal as pm
from psychmetaldemos.catalogue import GROUPS
from psychmetaldemos import finger_ring, noise_annulus, ring_check

root = Path(__file__).resolve().parents[1]
passed = 0


def check(cond, what):
    global passed
    if not cond:
        raise AssertionError(what)
    passed += 1


def quiet(fn, *args, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = pm.run(fn, *args, **kwargs)
    check(pm._S is None, f'{fn.__name__} closed its window')
    return result, out.getvalue()


# --- the list ------------------------------------------------------------------------------------------
sources = set(re.findall(r'"\.\./python/(\w+)\.py"', (root / 'phone' / 'pyproject.toml').read_text()))
listed = set()
for group, entries in GROUPS:
    for title, module, function, arguments, about in entries:
        check(callable(getattr(importlib.import_module(module), function)), f'{title}: {module}.{function}')
        if not module.startswith('psychmetaldemos.'):
            listed.add(module)
check(listed == sources, f'the app is given the files it lists: {sorted(listed ^ sources)}')
check(all((root / 'python' / f'{m}.py').exists() for m in sources), 'and they exist')

# --- the demos made for fingers ------------------------------------------------------------------------
os.environ['PM_MOCK_DISPLAY'] = '800x600@60'
os.environ['PM_MOCK_MOUSE'] = '20,0,0'
r, said = quiet(finger_ring.finger_ring, 0.5)
check(r['frames'] == 31 and r['ended_by'] == 'time' and r['touch_events'] == 3 and r['most_fingers'] == 1 and
      'Ended by: time' in said, 'finger_ring runs its time and reports')
r, said = quiet(ring_check.ring_check)
check(r == dict(wrong_in_the_ring=0, wrong_outside=0) and 'drawn exactly' in said, 'ring_check reads its frames back')

# The rectangles noise_annulus draws, with a pointer that moves as it is told.
drawn, real_draw, real_mouse = [], pm.draw_stimulus, pm.get_mouse


def spy(w, stimulus, rect=None, mask=None, **overrides):
    drawn.append(([float(v) for v in rect], mask is not None))
    return real_draw(w, stimulus, rect, mask, **overrides)


os.environ['PM_MOCK_MOUSE'] = '-1,0,0'
pm.draw_stimulus = spy
try:
    for scroll in (0, 1):
        for grain in (1, 3):
            # The pointer moves left a pixel a frame for a while, which would undo a scroll of one.
            path = iter([(400.0 - min(max(k - 5, 0), 8), 300.0 + k // 3, np.zeros(3, bool)) for k in range(1000)])
            pm.get_mouse = lambda w: next(path)
            drawn.clear()
            r, said = quiet(noise_annulus.noise_annulus, 0.4, scroll, grain)
            back = [rect for rect, masked in drawn if not masked]
            ring = [rect for rect, masked in drawn if masked]
            name = f'noise_annulus(scroll={scroll}, grain={grain})'
            check(r['frames'] == 25 and len(back) == 25 and len(ring) == 25, f'{name} draws each frame once')
            check(all((b[0] - a[0], b[2] - a[2]) == (scroll, scroll) for a, b in zip(back, back[1:])),
                  f'{name}: the background moves {scroll} a frame')
            check(all(a[0] <= 0 and a[2] >= 800 for a in back), f'{name}: and covers the window')
            check(all((q[0] - b[0]) % grain == 0 and q[1] % grain == 0 and (q[2] - q[0]) % grain == 0
                      for q, b in zip(ring, back)), f'{name}: the ring is on the background\'s cells')
            moved = [(b[0] - a[0], b[1] - a[1]) for a, b in zip(ring, ring[1:])]
            if scroll:
                check((0.0, 0.0) not in moved, f'{name}: the ring is never drawn still')
                check(moved[0] == (scroll, 0.0), f'{name}: untouched, it goes with the background')
            else:
                check(moved[0] == (0.0, 0.0) and any(m != (0.0, 0.0) for m in moved),
                      f'{name}: the ring is still until the pointer moves it')
finally:
    pm.draw_stimulus, pm.get_mouse = real_draw, real_mouse
print(f'PASS: {passed} checks of the phone app\'s list and its demos against the scripted engine.')
