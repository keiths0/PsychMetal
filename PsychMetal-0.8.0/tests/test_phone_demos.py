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
os.environ['PM_MOCK_DISPLAY_LINK_DEFAULT']='1'  # iOS 17+ native default
os.environ['PM_MOCK_DISPLAY'] = '800x600@60'
os.environ['PM_MOCK_MOUSE'] = '3,0,0'
r, said = quiet(finger_ring.finger_ring, 0.5)
# This is a time-limited demo, not a promised frame count on a loaded CI host.
check(5 <= r['frames'] <= 31 and r['ended_by'] == 'time' and r['touch_events'] == 3 and r['most_fingers'] == 1 and
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
            check(all(a[0] <= 100 and a[2] >= 700 and a[1] == 0 and a[3] == 600 for a in back), f'{name}: covers the centered square')
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

# Keep the phone catalogue in parity with every standalone Python demo.
expected={p.stem for p in (root/'python').glob('*_demo.py')} - {'kb_demo','kb_queue_demo'}
check(expected <= listed, f'all non-keyboard demos listed: missing {expected-listed}')
check(not {'kb_demo','kb_queue_demo'} & listed, 'keyboard demos excluded')

# Phone mask controls: a held second finger toggles only once, never exits.
from unittest.mock import patch
import stimulus_demo
os.environ['PM_MOCK_DISPLAY']='400x800@60'
os.environ['PM_MOCK_MOUSE']='-1,200,400'
states=iter([False,True,True,False,True,False])
carriers=[]; rectangles=[]
original=pm.draw_stimulus
calls=[0]
def record(w,stimulus,rect=None,mask=None,**kw):
    if mask is not None:
        carriers.append(stimulus); rectangles.append(rect)
    return original(w,stimulus,rect,mask,**kw)
def pointer(w):
    calls[0]+=1
    # Sixth read: trigger Escape without toggling another time.
    return 200,400,np.array([next(states),False,False])
def keys():
    a=np.zeros(256,dtype=bool);a[pm.kb_name('ESCAPE')]=calls[0]>=6
    return bool(a.any()),0,a
with patch.object(stimulus_demo.sys,'platform','ios'),patch.object(pm,'get_mouse',side_effect=pointer),patch.object(pm,'kb_check',side_effect=keys),patch.object(pm,'kb_wait'),patch.object(pm,'draw_stimulus',side_effect=record):
    pm.run(stimulus_demo.stimulus_demo,1)
check(len(carriers)==5,'second finger changes pattern without ending the demo')
check(carriers[0] is carriers[4] and carriers[1] is carriers[2] is carriers[3] and carriers[0] is not carriers[1], 'held finger toggles once per press')
check(all(0<=q[0]<q[2]<=400 and 0<=q[1]<q[3]<=800 for q in rectangles),'portrait mask fits the display')
print('PASS: all non-keyboard demos present; portrait mask and phone toggle/exit controls.')

# Predicted times must not conceal a real missed refresh, or bridge an unknown frame.
from psychmetaldemos.finger_ring import report, Touches
r=report(100,100,1/60,[1,1.016,1.032,1.048],0,Touches(),'test',
         dict(actualTimestamp=[1,1+2/60,float('nan'),1.1],actualStatus=[0,0,2,0]))
assert abs(r['mean_hz']-30)<1e-8 and r['unconfirmed_frames']==1
assert abs(r['longest_ms']-1000/30)<1e-8

# Portrait and landscape: background clipping stays fixed while its carrier
# scrolls; the annulus has no square clip and can enter either black margin.
real_fill = pm.fill_rect
for display, square, pointer_xy in (
    ('400x800@60', [0,200,400,600], (200,100)),
    ('800x400@60', [200,0,600,400], (100,200)),
):
    os.environ['PM_MOCK_DISPLAY'] = display
    os.environ['PM_MOCK_MOUSE'] = '-1,0,0'
    os.environ.pop('PM_MOCK_KEYS',None)
    for scroll in (0,1):
        for grain in (1,3):
            records=[]; clears=[]
            def draw_square(w,stimulus,rect=None,mask=None,**kw):
                clip=pm.clip(w)
                records.append((list(rect),mask is not None,None if clip is None else list(clip)))
                return real_draw(w,stimulus,rect,mask,**kw)
            def clear_black(w,color,rect=None):
                clears.append((list(color),rect,pm.clip(w)))
                return real_fill(w,color,rect)
            with patch.object(pm,'draw_stimulus',side_effect=draw_square), \
                 patch.object(pm,'get_mouse',return_value=(*pointer_xy,np.zeros(3,bool))), \
                 patch.object(pm,'fill_rect',side_effect=clear_black):
                quiet(noise_annulus.noise_annulus,.04,scroll,grain)
            backgrounds=[q for q in records if not q[1]]
            rings=[q for q in records if q[1]]
            check(backgrounds and all(q[2]==square for q in backgrounds),'fixed centered square clip in either orientation')
            check(rings and all(q[2] is None for q in rings),'annulus is not clipped to background square')
            check(len(clears)==len(backgrounds) and
                  all(c==[0,0,0] and rect is None and clip is None for c,rect,clip in clears),
                  'each frame clears the whole window to black before square clipping')
            active_background=None
            for rect, masked, clip in records:
                if not masked:
                    active_background=rect
                else:
                    check((rect[0]-active_background[0]) % grain == 0 and
                          (rect[1]-active_background[1]) % grain == 0,
                          'every ring wrap copy retains scrolling background cell alignment')
            # The scripted renderer validates procedural calls, not their pixels.
            # Check placement outside the square and the absence of a ring clip.
            if display.startswith('400'):
                check(any(q[0][1]<200 and q[0][3]<=200 for q in rings),
                      'ring can move fully into upper black margin')
            else:
                check(any(q[0][0]<200 and q[0][2]<=200 for q in rings),
                      'ring can move fully into left black margin')
print('PASS: centered noise square, black margins, unrestricted annulus and scroll clipping in portrait/landscape, both grain sizes.')
