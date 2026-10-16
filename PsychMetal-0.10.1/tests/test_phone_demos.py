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
from psychmetaldemos import finger_ring
import hidden_ring_demo
import ring_check   # a developer check in python/, not shipped in the app

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

# The rectangles hidden_ring_demo draws, with a pointer that moves as it is told.
drawn, real_draw, real_mouse, real_keys = [], pm.draw_stimulus, pm.get_mouse, pm.kb_check


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
            # Stop after 25 submitted frames, rather than assuming a shared
            # runner can always present 25 frames within 0.4 wall-clock seconds.
            def stop_after_frames():
                pressed, stamp, keys = real_keys()
                keys = keys.copy()
                keys[pm.kb_name('ESCAPE')] = sum(not masked for _, masked in drawn) >= 25
                return bool(keys.any()), stamp, keys
            pm.kb_check = stop_after_frames
            r, said = quiet(hidden_ring_demo.hidden_ring_demo, 5.0, scroll, grain)
            back = [rect for rect, masked in drawn if not masked]
            ring = [rect for rect, masked in drawn if masked]
            name = f'hidden_ring_demo(speed={scroll}, cell={grain})'
            check(r['frames'] == 25 and r['ended_by'] == 'Escape' and len(back) == 25 and len(ring) == 25, f'{name} draws each frame once')
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
    pm.draw_stimulus, pm.get_mouse, pm.kb_check = real_draw, real_mouse, real_keys
print(f'PASS: {passed} checks of the phone app\'s list and its demos against the scripted engine.')

# Keep the phone catalogue in parity with every standalone Python demo but the
# keyboard ones, the minimal template and the stimulus example (DEMO-PARITY.md).
expected={p.stem for p in (root/'python').glob('*_demo.py')} - {'kb_demo','kb_queue_demo','minimal_demo','stimulus_demo'}
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
                quiet(hidden_ring_demo.hidden_ring_demo,.04,scroll,grain)
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

# The sound demos as a phone runs them: fingers through touch_events, not the mouse.
import math
import audio_demo
import modulation_match_demo


def fingers(script):
    """touch_events from a script: one list of (finger, phase, x, y) per call; 0 down, 1 moved, 2 up."""
    calls = iter(script)

    def touch_events(w):
        rows = next(calls, [])
        return [[pm.get_secs(), finger, phase, x, y] for finger, phase, x, y in rows], 0
    return touch_events


def tap(x, y):
    return [[(1, 0, x, y)], [(1, 2, x, y)]]


os.environ['PM_MOCK_DISPLAY'] = '390x844@60'
os.environ['PM_MOCK_MOUSE'] = '-1,0,0'
rect = [0, 0, 390, 844]
buttons = audio_demo.buttons_for(rect)
middle = {n: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) for n, b in buttons.items()}
script = ([[]] * 5 + [[(1, 0, *middle['Record'])]] + [[]] * 19 + [[(1, 2, *middle['Record'])]] + [[]] * 10 +
          tap(*middle['Play']) + [[]] * 30 + tap(*middle['Quit']))
with patch.object(audio_demo.sys, 'platform', 'ios'), patch.object(pm, 'touch_events', side_effect=fingers(script)):
    r, said = quiet(audio_demo.audio_demo, 10)
check(r['log'] == ['record', 'play'] and abs(r['recorded_seconds'] - 20 / 60) < 3 / 60 and math.isfinite(r['played_at']),
      f'audio_demo by finger: hold Record, lift, tap Play, tap Quit ({r})')
check(not pm.audio_status()['open'], 'audio_demo closes audio')
# Drop the release itself, as an overflowed native touch queue can do. The
# recorder must stop and the later Play/Quit taps must still be actionable.
reader = fingers(script)
call_index = -1
def lost_release(w):
    global call_index
    call_index += 1
    rows, dropped = reader(w)
    return ([], 1) if call_index == 25 else (rows, dropped)
with patch.object(audio_demo.sys, 'platform', 'ios'), patch.object(pm, 'touch_events', side_effect=lost_release):
    r, said = quiet(audio_demo.audio_demo, 10)
check(r['log'] == ['record', 'play'] and math.isfinite(r['played_at']),
      'a lost touch release stops recording and leaves later phone controls usable')


places = modulation_match_demo.layout(rect)
cx, cy, radius = places['dial']
arc = [[(1, 1 if k else 0, cx + 0.8 * radius * math.cos(a), cy + 0.8 * radius * math.sin(a))]
       for k, a in enumerate(np.linspace(0, math.pi / 2, 8))]
centre = lambda box: ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
script = ([[]] * 5 + tap(*centre(places['buttons']['Match'])) + [[]] * 5 + arc + [[(1, 2, cx, cy + 0.8 * radius)]] +
          tap(*centre(places['buttons']['Match'])) + [[]] * 5 + tap(*centre(places['buttons']['Quit'])))
with patch.object(modulation_match_demo.sys, 'platform', 'ios'), patch.object(modulation_match_demo, 'FEEDBACK', 0.02), \
     patch.object(pm, 'touch_events', side_effect=fingers(script)):
    trials, said = quiet(modulation_match_demo.modulation_match_demo, 20, 5)
check(len(trials) == 2 and trials[0]['response'] == trials[0]['start'], f'matching demo by finger: Match untouched ({trials})')
check(abs(math.remainder(trials[1]['response'] - trials[1]['start'] - math.pi / 2, 2 * math.pi)) < 1e-9,
      'matching demo by finger: a quarter turn of the dial is a quarter cycle')
check(not pm.audio_status()['open'], 'matching demo closes audio')
print('PASS: the sound demos by finger on a portrait phone: record, play, quit; the dial, Match, quit.')
