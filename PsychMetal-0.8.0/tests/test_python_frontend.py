#!/usr/bin/env python3
"""The psychmetal package through the real Python front end (PsychMetalPython.cpp),
against the scripted engine. Run by tests/test_frontends.py, which builds it."""
import os
import signal
import threading
import time
import warnings

import numpy as np

import psychmetal as pm

passed = 0


def check(cond, what):
    global passed
    if not cond:
        raise AssertionError(what)
    passed += 1


def raises(fn, *args, message=None, id=None, exc=pm.PsychMetalError, **kw):
    try:
        fn(*args, **kw)
    except exc as e:
        if message is not None:
            assert str(e) == message, f'expected {message!r}, got {str(e)!r}'
        if id is not None:
            assert getattr(e, 'id', None) == id, f'expected id {id}, got {getattr(e, "id", None)}'
        return e
    raise AssertionError(f'{getattr(fn, "__name__", fn)} accepted invalid input')


core = pm._core
check(pm.version() == '0.8.0' and core.version() == '0.8.0', 'versions agree')

# Environment is available before opening; exporting is explicit and non-destructive.
import json, tempfile
from pathlib import Path
e=pm.environment_report()
check(e['gpuName']=='scripted GPU' and e['engineVersion']=='0.8.0' and e['schemaVersion']==1,'native environment metadata')
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/'environment.json'
    pm.export_environment_report(path)
    check(json.loads(path.read_text())==e,'environment JSON round trip')
    raises(pm.export_environment_report,path,exc=FileExistsError)
from psychmetal.environment import export
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/'unknown.json';export({'unknown':np.nan,'values':np.array([1.,np.inf])},path)
    check(json.loads(path.read_text())=={'unknown':None,'values':[1.,None]},'strict JSON with unknown values')

# --- window, rect, time -------------------------------------------------------------
w, rect, ifi = pm.open_window(0, [0, 0, 0])
check(pm.environment_report(w)['window']['presentation']=='direct','environment includes window configuration')
check(list(rect) == [0, 0, 800, 600] and abs(ifi - 1 / 60) < 1e-12, 'open_window returns w, rect, ifi')
check(list(pm.rect(w)) == [0, 0, 800, 600] and pm.window_size(w) == (800, 600), 'rect and window_size')
check(abs(pm.get_flip_interval(w) - ifi) < 1e-12, 'get_flip_interval before 30 frames is nominal')
t0 = pm.get_secs(); t1 = pm.wait_secs(0.01); check(t1 - t0 >= 0.01, 'wait_secs waits')
t2 = pm.wait_secs('UntilTime', pm.get_secs() + 0.005); check(t2 > t1, "wait_secs('UntilTime', t)")
check(pm.color_range(w, 1) == 255 and pm.color_range(w, 255) == 1, 'color_range returns the old range')
check(np.allclose(pm.background_color(w, [255, 0, 0]), [1, 0, 0, 1]), 'background_color converts from 0..255')
raises(pm.open_window, message='PsychMetal is already open. Close the existing window first.')

# --- every shape --------------------------------------------------------------------
pm.fill_rect(w, [255, 0, 0], [10, 10, 50, 50])
pm.frame_rect(w, 128, np.array([[10, 60], [10, 60], [50, 90], [50, 90]]), 2)
pm.fill_oval(w, [0, 255, 0, 128], [100, 100, 150, 150])
pm.frame_oval(w, None, [100, 100, 150, 150])
pm.draw_dots(w, [[10, 20, 30], [40, 50, 60]], 4, 255, [0, 0], 1)
pm.draw_lines(w, [[0, 100, 0, 100], [0, 0, 100, 100]], 2, 255)
pm.draw_gabor(w, 255, [200, 200, 300, 300], 0.2, 0.05, 45, 90)
check(pm.draw_noise(w, [300, 300, 340, 330], 7, 'normal', 'colour', [128, 128, 128], 40) == 7, 'draw_noise returns its seed')
seed, vals = pm.draw_noise(w, [0, 0, 4, 3], 9, values=True)
check(seed == 9 and vals.shape == (3, 4), 'draw_noise(values=True) also returns the values')
diag = core.diagnostic()[1]
check(diag['shapesAppended'] == 13, f"all shapes reached the engine ({diag['shapesAppended']})")
raises(pm.draw_dots, w, [[1], [np.nan]], message='Dot positions must be 2xN.')
raises(pm.draw_lines, w, [[0, 1, 2], [0, 1, 2]], message='Line endpoints must be 2xN with N even: pairs of points.')
raises(pm.fill_rect, w, [1, 2], message='Colour must be scalar grey, RGB or RGBA, optionally one per shape.', id='PsychMetal:Color')
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter('always')
    pm.fill_rect(w, 300)
check(any('PsychMetal:ColorRange' in str(c.message) for c in caught), 'out-of-range colour warns')

# --- noise ------------------------------------------------------------------------------
n1 = pm.noise_values(w, [0, 0, 5, 3], 11, 'uniform', 'mono', 128, 50)
n2 = pm.noise_values(w, [0, 0, 5, 3], 11, 'uniform', 'mono', 128, 50)
check(n1.shape == (3, 5) and np.array_equal(n1, n2) and n1.min() >= 0 and n1.max() <= 255, 'noise_values: shape, determinism, range')
n3 = pm.noise_values(w, [0, 0, 4, 2], 11, 'normal', 'colour', [128, 128, 128], 50)
check(n3.shape == (2, 4, 3) and n3.flags.writeable, 'colour noise is (H, W, 3) and writable')
nc = core.noise_values(5, 3, 11, 0, 0, (128 / 255,) * 3, 50 / 255)
check(np.max(np.abs(nc * 255 - n1)) < 1e-9, 'noise_values matches the engine call')

# --- textures: every memory layout reads the same texels --------------------------------
img = np.zeros((2, 3, 3))
img[1, 0] = [0.25, 0.5, 0.75]
img[0, 1] = [1, 0, 0.5]


def probes():
    s = core.diagnostic()[1]
    return np.array(s['lastShapeRect']), np.array(s['lastShapeColor'])


layouts = {
    'C-ordered float64': img,
    'Fortran-ordered float64': np.asfortranarray(img),
    'float32': img.astype(np.float32),
    'transposed view': np.ascontiguousarray(img.transpose(1, 0, 2)).transpose(1, 0, 2),
    'strided slice': np.repeat(np.repeat(img, 2, axis=0), 2, axis=1)[::2, ::2],
    'negative strides': img[::-1, ::-1][::-1, ::-1],
    'uint8': (img * 255).round().astype(np.uint8),
}
for name, a in layouts.items():
    t = pm.make_texture(w, a)
    below, right = probes()
    check(np.allclose(below, [0.25, 0.5, 0.75, 1], atol=3e-3) and np.allclose(right, [1, 0, 0.5, 1], atol=3e-3),
          f'{name} image reaches the engine untransposed')
    pm.close_texture(w, t)
flipped = pm.make_texture(w, img[::-1])          # rows reversed: row 1 becomes row 0
below, right = probes()
check(np.allclose(below, [0, 0, 0, 1], atol=1e-3) and np.allclose(right, [0, 0, 0, 1], atol=1e-3)
      and True, 'a reversed view is read as reversed, not copied from the base')
grey = pm.make_texture(w, np.eye(3, dtype=bool))
check(np.isnan(probes()[0][1]), 'grey images stay one channel')
t = pm.make_texture(w, img)
pm.update_texture(w, t, np.zeros((4, 4, 4)))


# Texture draws, as the engine receives them: one row per draw,
# [handle, src (normalised) x4, dst x4, angle (radians), tint x4, filter].
class Spy:
    def __init__(self, real):
        self.real, self.rows, self.calls = real, [], 0

    def __getattr__(self, name):
        f = getattr(self.real, name)
        if name != 'draw_textures':
            return f

        def record(*a):
            self.calls += 1
            h, s, d, ang, tint, fm = (np.asarray(x) for x in a)
            check(all(x.dtype == float and x.shape == (h.size, 4) for x in (s, d, tint)) and
                  all(x.dtype == float and x.shape == (h.size,) for x in (h, ang, fm)),
                  'draw_textures passes float64 (N,) and (N, 4) arrays')
            self.rows += [np.hstack([h[k], s[k], d[k], ang[k], tint[k], fm[k]]) for k in range(h.size)]
            return f(*a)
        return record


def engine_rows(fn):
    spy = Spy(core)
    pm._core = spy
    try:
        fn()
    finally:
        pm._core = core
    return spy.calls, np.array(spy.rows)


# t is 4 by 4 after its update, grey 3 by 3; the window is 800 x 600.
cases = {
    'defaults: whole texture, native size, centred': (
        lambda: pm.draw_textures(w, [t, grey]),
        [[t, 0, 0, 1, 1, 398, 298, 402, 302, 0, 1, 1, 1, 1, 1],
         [grey, 0, 0, 1, 1, 398.5, 298.5, 401.5, 301.5, 0, 1, 1, 1, 1, 1]]),
    'every argument, reversed destination normalised': (
        lambda: pm.draw_texture(w, t, [0, 0, 3, 1], [40, 30, 10, 5], 90, 0, 51, [255, 0, 0]),
        [[t, 0, 0, 0.75, 0.25, 10, 5, 40, 30, np.pi / 2, 1, 0, 0, 0.2, 0]]),
    'one texture at several places': (
        lambda: pm.draw_textures(w, t, None, np.array([[0, 100], [0, 100], [10, 150], [10, 120]])),
        [[t, 0, 0, 1, 1, 0, 0, 10, 10, 0, 1, 1, 1, 1, 1], [t, 0, 0, 1, 1, 100, 100, 150, 120, 0, 1, 1, 1, 1, 1]]),
    'per-draw values and colours, shared source': (
        lambda: pm.draw_textures(w, [t, grey], [0, 0, 1, 1], [5, 5, 25, 25], [0, 180], [1, 0], [255, 102],
                                 np.array([[255, 0], [0, 255], [0, 0]])),
        [[t, 0, 0, 0.25, 0.25, 5, 5, 25, 25, 0, 1, 0, 0, 1, 1],
         [grey, 0, 0, 1 / 3, 1 / 3, 5, 5, 25, 25, np.pi, 0, 1, 0, 0.4, 0]]),
}
for what, (draw, expected) in cases.items():
    calls, rows = engine_rows(draw)
    check(calls == 1 and rows.shape == np.shape(expected) and np.allclose(rows, expected),
          f'draw_textures, {what}:\n{rows}')
raises(pm.draw_textures, w, [t, grey, t], None, np.zeros((4, 2)), message='Supply one dst_rect, or one per item (3).')
raises(pm.draw_textures, w, [t, 99], message='Unknown texture handle.')
raises(pm.draw_textures, w, [], message='Invalid texture handle.')
raises(pm.draw_texture, w, t, None, None, 0, [255, 0, 0, 128], message=pm._FILTER_MESSAGE)
raises(pm.draw_textures, w, t, [0, 0, 1], message='src_rect must be [left top right bottom] in texture pixels, or 4xN.')
raises(pm.draw_textures, w, t, None, np.zeros((3, 2)),
       message='dst_rect must be [left top right bottom] in window pixels, or 4xN.')
raises(pm.draw_textures, w, t, None, None, None, None, None, np.zeros((2, 2)),
       message='Colour must be scalar grey, RGB or RGBA, optionally one per shape.')
raises(pm.draw_textures, w, [t, t], None, None, None, None, None, np.zeros((3, 3)),
       message='Supply one texture, or one per item (3).')
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter('always')
    pm.draw_textures(w, [t, t], None, None, None, None, [255, 300])
check(any('globalAlpha of 300' in str(c.message) for c in caught), 'draw_textures warns on an out-of-range alpha')
one, rect2 = np.ones(2), np.zeros((2, 4))
raises(core.draw_textures, np.array([1.0, 99.0]), rect2, rect2, np.zeros(2), np.ones((2, 4)), one,
       message='Invalid or expired texture handle.')
raises(core.draw_textures, np.array([t, t], dtype=np.float32), rect2, rect2, np.zeros(2), np.ones((2, 4)), one,
       message='DrawTextures arguments must be real double arrays.')
raises(core.draw_textures, np.array([t, t], dtype=float), np.zeros((2, 3)), rect2, np.zeros(2), np.ones((2, 4)), one,
       message='DrawTextures expects handles, angles and filter modes as 1xN and srcRects, dstRects and tints as 4xN.')
raises(core.draw_textures, np.array([t, 1.5]), rect2, rect2, np.zeros(2), np.ones((2, 4)), one,
       message='texture handle must be a nonnegative integer in range.')
raises(core.draw_textures, np.array([float(t)]), np.zeros((1, 4)), np.zeros((1, 4)), np.zeros(1), np.full((1, 4), 2.0),
       np.ones(1), message='Invalid texture rectangle or tint.')
pm.close_texture(w, t)
raises(pm.draw_texture, w, t, message='Unknown texture handle.')
raises(core.make_texture, np.zeros((2, 2), dtype=np.float16), message='Image must be dense real uint8, single, double, or logical HxWxC.')
raises(core.make_texture, np.zeros(5), message='Image must be dense real uint8, single, double, or logical HxWxC.')
raises(core.make_texture, np.zeros((2, 2, 2)), message='Image dimensions must be 1..16384 and have 1, 3, or 4 channels.')
raises(core.make_texture, np.array([[1.0, np.nan]]), message='Texture pixels must be finite.')
raises(core.make_texture, [[1.0, 2.0]], message='Image must be dense real uint8, single, double, or logical HxWxC.')
raises(core.add_shapes, np.zeros(1), np.ones(1), np.zeros((1, 3)), np.ones((1, 4)), np.zeros((1, 4)),
       message='AddShapes expects kind and param as 1xN and rect, color and extra as 4xN.')
raises(core.add_shapes, np.zeros(1, np.float32), np.ones(1), np.zeros((1, 4)), np.ones((1, 4)), np.zeros((1, 4)),
       message='AddShapes arguments must be real double arrays.')

# --- readback is off unless asked for ---------------------------------------------------
raises(pm.get_image, w, message='GetImage requires a window opened with readback.')
raises(core.get_image, message='GetImage requires a window opened with readback.')
check(core.diagnostic()[1]['readbackEnabled'] is False, 'a default window reports no readback')

# --- presentation -----------------------------------------------------------------------
vbl, onset, ret, missed, slipped = pm.flip(w)
check(onset == vbl and ret >= vbl and missed == 0 and slipped == 0, 'flip returns the Screen five')
vbl2, _, _, missed2, _ = pm.flip(w, vbl + 2 * ifi)
check(abs(vbl2 - (vbl + 2 * ifi)) < 1e-6 and missed2 < 0, 'flip(w, when) meets a future deadline; missed < 0')
check(pm.prepare_flip(w) > 0, 'prepare_flip returns a token')
when, call_ms = pm.present_now(w)
check(when > 0 and call_ms >= 0, 'present_now')
pm.set_display_sync(w, True)
anchor, period, samples = pm.grid_anchor(w)
check(abs(anchor - vbl2) < 1e-9 and samples > 0, 'grid_anchor')
check(abs(pm.next_refresh(w, vbl2 + 0.1 * ifi) - (vbl2 + ifi)) < 1e-9, 'next_refresh')
check(abs(pm.next_phase(w, vbl2, 0.5) - (vbl2 + 0.5 * ifi)) < 1e-9, 'next_phase')
woke, lead, deadline = pm.wait_to_draw(w, vbl2 + 3 * ifi)
check(lead > 0 and deadline < vbl2 + 3 * ifi, 'wait_to_draw')
pm.prefetch_drawable(w, False)
raises(core.flip, -1.0, message='Target must be nonnegative.')
raises(core.flip, float('nan'), message='target must be finite.')
raises(core.flip, 'x', message='target must be a real numeric scalar.')
raises(pm.flip, w, -1, message="'when' must be zero or a positive GetSecs timestamp.")

# --- the GIL is released while the engine blocks --------------------------------------
ticks = [0]
stop = threading.Event()


def spin():
    while not stop.is_set():
        ticks[0] += 1


spinner = threading.Thread(target=spin)
spinner.start()
time.sleep(0.01)
before = ticks[0]
for _ in range(6):
    pm.flip(w)
during = ticks[0] - before
stop.set(); spinner.join()
check(during > 1000, f'a Python thread ran {during} iterations during six flips')

# --- diagnostics --------------------------------------------------------------------------
d = pm.diagnostic(w)
h, s = core.diagnostic()
check(h.shape[1] == 16 and len(s) == 60, 'raw diagnostic: 16 history columns, 60 summary fields')
check(list(s)[:3] == ['confirmedPresentations', 'missingPresentedTimes', 'lastTargetErrorMs'], 'summary field order')
check(d['summary']['flips'] == 8 and np.isfinite(d['summary']['measuredRefreshHz']), 'diagnostic summary and refresh fit')
check(set(['flipNumber', 'actualTimestamp', 'pipelineLeadMs', 'startup']) <= set(d), 'diagnostic fields')

# --- input ------------------------------------------------------------------------------------
x, y, buttons = pm.get_mouse(w)
check(buttons.dtype == bool and buttons.shape == (3,), 'get_mouse buttons are bool[3]')
pm.set_mouse(w, 320, 240)
check(pm.get_mouse(w)[:2] == (320, 240), 'set_mouse moves the cursor; get_mouse reads it back')
raises(pm.set_mouse, w, 9999, 0, message='SetMouse position must be inside the window, in pixels.')
raises(pm.set_mouse, w, 'x', 0, message='set_mouse x and y must be finite real numbers, in window pixels.')
raises(core.set_mouse, 1, exc=TypeError)
down, secs, code = pm.kb_check()
check(down is False and code.dtype == bool and code.shape == (256,), 'kb_check key_code is bool[256]')
check(pm.kb_name('ESCAPE') == 40 and pm.kb_name(40) == 'ESCAPE' and pm.kb_name('escape') == 40, 'kb_name uses 0-based indices')
mask = np.zeros(256, bool); mask[[3, 40]] = True
check(pm.kb_name(mask) == ['a', 'ESCAPE'], 'kb_name of a key_code lists names')
pm.hide_cursor(); pm.show_cursor()
pm.kb_queue_create(); pm.kb_queue_start(); time.sleep(0.02)
st = pm.kb_queue_status()
check(st['running'] and st['scans'] > 0, 'keyboard queue polls')
events, dropped = pm.kb_queue_get_events()
check(events.shape == (0, 3) and dropped == 0, 'no events without key presses')
pressed, fp, fr, lp, lr = pm.kb_queue_check()
check(pressed is False and fp.shape == (256,), 'kb_queue_check')
pm.kb_queue_stop(); pm.kb_queue_flush(); pm.kb_queue_release()
check(not pm.kb_queue_status()['created'], 'kb_queue_release')
raises(pm.kb_queue_create, np.ones(10), message='keyMask must have 256 finite real entries.')
raises(core.kb_queue_create, np.full(256, np.nan), 0.002, message='Key mask must be finite.')
raises(core.kb_queue_start, message='Create a keyboard queue first.')

# --- modes, with the window closed ---------------------------------------------------------
pm.close(w)

# --- dropped frames are reported, not raised ----------------------------------------------------
os.environ['PM_MOCK_DROP'] = '3'
try:
    wd, _, ifi_d = pm.open_window(0)
    info = pm.flip_info(wd)
    check(info['flips'] == 0 and info['droppedFrames'] == 0 and info['dropped'] is False, 'flip_info before any flip')
    # This window does not wait for confirmation, so flip returns before the display
    # has reported on its frame: what became of it is learned afterwards.
    early, seen, shown, counts = [], [], [], []
    for _ in range(6):
        vbl, _, _, _, _ = pm.flip(wd)
        info = pm.flip_info(wd)
        early.append((info['confirmed'], info['dropped'], info['droppedFrames']))
        pm.wait_secs(ifi_d)
        info = pm.flip_info(wd)
        seen.append(info['dropped']); shown.append(info['confirmed']); counts.append(info['droppedFrames'])
        check(np.isfinite(vbl), 'a dropped frame still returns a time')
    check(early == [(False, False, n) for n in (0, 0, 0, 1, 1, 1)],
          'straight after flip the display has reported nothing of its frame, and the count has not moved')
    check(seen == [False, False, True, False, False, True] and shown == [not s for s in seen] and counts == [0, 0, 1, 1, 1, 2],
          'a drop reported after flip has returned is flagged and counted by flip_info')
    check(info['droppedFrames'] == 2 and info['flips'] == 6 and info['confirmed'] is False, 'flip_info counts dropped frames')
    d = pm.diagnostic(wd)
    check(d['summary']['droppedFrames'] == 2 and list(d['actualStatus']) == [0, 0, 1, 0, 0, 1], 'diagnostic records dropped frames')
    check(d['summary']['lastVblConfirmed'] is False, 'flip itself returned before any report')
    raises(pm.flip_info, wd + 1, message='flip_info requires the window handle from open_window.')
    pm.close(wd)
finally:
    del os.environ['PM_MOCK_DROP']
raises(pm.flip, w, message='PsychMetal is not open.')

# --- open_window as the subject of a with statement ---------------------------------------------
opened = pm.open_window(0)
check(isinstance(opened, tuple) and len(opened) == 3 and opened[2] > 0, 'open_window still returns the tuple (w, rect, ifi)')
pm.close(opened[0])
with pm.open_window(0) as (wc, rc, ic):
    pm.fill_rect(wc, 255)
    pm.flip(wc)
    check(rc[2] == 800 and ic > 0, 'with open_window(...) as (w, rect, ifi) gives the same three')
raises(pm.flip, wc, message='PsychMetal is not open.')
try:
    with pm.open_window(0) as (wc, _, _):
        raise RuntimeError('stopped')
except RuntimeError as stopped:
    check(str(stopped) == 'stopped', 'an error inside the block is passed on')
raises(pm.flip, wc, message='PsychMetal is not open.')
with pm.open_window(0) as (wc, _, _):
    pm.close(wc)                                    # closed by hand inside the block: leaving it is then quiet
with pm.open_window(0) as (first, _, _):
    pass
second, _, _ = pm.open_window(0)                    # a later window is not closed by an earlier block's tuple
opened.__exit__(None, None, None)
check(pm.rect(second)[2] == 800, 'leaving a block closes only the window it opened')
pm.close(second)
m = pm.resolutions(0)
check(len(m) == 2 and m[0]['width'] == 800, 'resolutions lists modes as dicts')
check(pm.resolution(0, 1024, 768)['width'] == 800, 'resolution sets and returns the old mode')
raises(core.set_mode, 0, 640, 480, message='No matching display mode.', id='PsychMetal:Mode')
check(pm.resolution(0,1024,768,refresh_hz=60)['width']==800, 'explicit refresh mode')
raises(pm.resolution,0,1024,768,refresh_hz=59.94,id='PsychMetal:Mode')
raises(pm.resolution,0,1024,768,refresh_hz=float('nan'))
raises(pm.resolution,0,refresh_hz=60)
raises(core.set_mode,0,1024,768,-60,id='PsychMetal:Mode')

core.prepare_app()
raises(core.open_session, 3, 3, 1, 1, 1, message='Screen index 3 is out of range; 1 display(s) are active.', id='PsychMetal:Screen')
raises(core.open_session, 0, 1, 1, 1, 1, message='Drawable count must be 2 or 3.')
raises(core.open_session, 0, 4, 1, 1, 1, message='maximum drawable count must be a nonnegative integer in range.')
raises(core.open_session, 0.5, 3, 1, 1, 1, message='screen index must be a non-negative integer, or -1 for the last display.')
raises(core.open_session, 0, 3, 2, 1, 1, message='wait for confirmation must be a nonnegative integer in range.')

# --- readback: the frame comes back as drawn, in numpy's layout --------------------------
check(pm._S is None, 'the window is closed before the readback checks')
raises(pm.open_window, 0, readback=2, message='readback must be true or false.')
wr, rrect, _ = pm.open_window(0, [51, 102, 153], readback=True)
check(core.diagnostic()[1]['readbackEnabled'] is True, 'a readback window reports it')
shot = pm.get_image(wr)
check(shot.shape == (600, 800, 3) and shot.dtype == np.uint8 and (shot == [51, 102, 153]).all(),
      'get_image after open is the background, (H, W, 3) uint8, RGB')
pm.fill_rect(wr, [255, 128, 0], [10, 20, 110, 70])     # wider than tall, off the diagonal
pm.flip(wr)
shot = pm.get_image(wr)
check((shot[20:70, 10:110] == [255, 128, 0]).all(), 'the rectangle is where it was drawn, rows then columns')
check((shot[19, 10:110] == [51, 102, 153]).all() and (shot[20:70, 110] == [51, 102, 153]).all()
      and (shot[70, 10:110] == [51, 102, 153]).all() and (shot[20:70, 9] == [51, 102, 153]).all(),
      'and stops at its edges')
part = pm.get_image(wr, [5, 15, 120, 80])
check(part.shape == (65, 115, 3) and np.array_equal(part, shot[15:80, 5:120]), 'a rect returns that part of the frame')
check(np.array_equal(pm.get_image(wr, np.array([5.0, 15, 120, 80])), part), 'a numpy rect is accepted')
part[:] = 0
check((pm.get_image(wr, [5, 15, 120, 80]) != 0).any(), 'the result is the caller\'s own array')
rgb = np.zeros((2, 3, 3), np.uint8); rgb[0, 1] = [10, 20, 30]; rgb[1, 0] = [40, 50, 60]
tr = pm.make_texture(wr, rgb)
pm.draw_texture(wr, tr, None, [200, 100, 203, 102], 0, 0)
pm.flip(wr)
check(np.array_equal(pm.get_image(wr, [200, 100, 203, 102]), rgb), 'a texture reads back untransposed, channels in order')
bad = 'GetImage rect must be [left top right bottom] in whole pixels inside the window.'
for r in ([0, 0, 801, 10], [0, 0, 10, 601], [-1, 0, 10, 10], [0.5, 0, 10, 10], [10, 10, 10, 20], [10, 20, 30, 20]):
    raises(pm.get_image, wr, r, message=bad)
raises(pm.get_image, wr, [0, 0, 10], message=bad)
raises(pm.get_image, wr, 'abcd', message=bad)
raises(core.get_image, (0, 0, float('nan'), 10), message=bad)
pm.close(wr)
wr, _, _ = pm.open_window(0, None, None, None, None, None, 60, True)
check(core.diagnostic()[1]['readbackEnabled'] is True and abs(pm.get_flip_interval(wr) - 1 / 60) < 1e-12,
      'readback follows refresh_hz positionally')
pm.close(wr)

# --- partial updates, blending, linearization, text and the link ------------------------------
raises(pm.open_window, 0, bit_depth=12, message='bitDepth must be 8 or 10.')
core.prepare_app()
raises(core.open_session, 0, 3, 0, 1, 1, None, 1, 9, message='Bit depth must be 8 or 10.')
wn, _, _ = pm.open_window(0, 0, readback=True)
img = np.zeros((4, 6, 3), np.uint8)
tn = pm.make_texture(wn, img)
patch = np.zeros((2, 3, 3), np.uint8); patch[0, 1] = [10, 20, 30]; patch[1, 2] = [40, 50, 60]      # wider than tall
pm.update_texture(wn, tn, patch, [2, 1, 5, 3])
img[1:3, 2:5] = patch
pm.draw_texture(wn, tn, None, [100, 50, 106, 54], 0, 0); pm.flip(wn)
check(np.array_equal(pm.get_image(wn, [100, 50, 106, 54]), img), 'a partial update lands at [left, top], rows then columns')
pm.update_texture(wn, tn, np.asfortranarray(patch[:, ::-1]), np.array([2.0, 1, 5, 3]))
img[1:3, 2:5] = patch[:, ::-1]
pm.draw_texture(wn, tn); pm.flip(wn)
check(pm._S['textures'][tn] == (6, 4, 6, 4), 'a partial update keeps the texture size')
bad = 'The update_texture rect must be [left top right bottom] in whole texture pixels, the size of the image.'
for r in ([2, 1, 4, 3], [2, 1, 5, 4], [2.5, 1, 5.5, 3], [2, 1, 5], 'abcd'):
    raises(pm.update_texture, wn, tn, patch, r, message=bad)
raises(pm.update_texture, wn, tn, patch, [4, 1, 7, 3], message='A partial update must lie inside the texture, at whole pixels.')
kind = "A partial update must have the texture's type (uint8 or logical, or float) and channel count."
raises(pm.update_texture, wn, tn, patch.astype(float), [2, 1, 5, 3], message=kind)
raises(pm.update_texture, wn, tn, patch[:, :, 0], [2, 1, 5, 3], message=kind)
raises(core.update_texture, tn, patch, 2, message='update_texture takes a handle and an image, and optionally left and top.')

pm.fill_rect(wn, [100, 50, 200], [10, 10, 20, 20])
check(pm.blend_function(wn) == 'alpha' and pm.blend_function(wn, 'ADD') == 'alpha', 'blend_function returns the old mode')
pm.fill_rect(wn, [20, 30, 100], [10, 10, 20, 20])
check(pm.blend_function(wn, 'alpha') == 'add', 'and reports the one in force')
pm.fill_rect(wn, [1, 2, 3], [30, 10, 40, 20])
pm.flip(wn); shot = pm.get_image(wn)
check(shot[15, 15].tolist() == [120, 80, 255] and shot[15, 35].tolist() == [1, 2, 3],
      'the blend mode belongs to each draw as it is queued')
raises(pm.blend_function, wn, 'multiply', message="The blend mode must be 'alpha', 'add' or 'copy'.")
raises(pm.blend_function, wn, 1, message="The blend mode must be 'alpha', 'add' or 'copy'.")
raises(core.set_blend_mode, 3, message='blend mode must be a nonnegative integer in range.')

check(pm.linearize(wn) is None and pm.linearize(wn, [2, 1, 0.5]) is None, 'linearize is off at open')
pm.fill_rect(wn, 64, [10, 10, 20, 20]); pm.flip(wn)
v = 64 / 255
check(pm.get_image(wn, [10, 10, 20, 20])[5, 5].tolist() == [round(255 * v ** 0.5), 64, round(255 * v ** 2)],
      'a gamma per channel, in R G B order')
table = np.column_stack([np.linspace(0, 1, 5), np.linspace(1, 0, 5), [0, 0, 1, 1, 1]])      # (5, 3)
check(np.array_equal(pm.linearize(wn, table), [2, 1, 0.5]), 'linearize returns the old setting')
pm.fill_rect(wn, 51, [10, 10, 20, 20]); pm.flip(wn)
check(pm.get_image(wn, [10, 10, 20, 20])[5, 5].tolist() == [51, 204, 0], 'a table is (N, 3): a row per entry, a column per channel')
pm.linearize(wn, np.asfortranarray(table)[::-1].astype(np.float32))
pm.fill_rect(wn, 51, [10, 10, 20, 20]); pm.flip(wn)
check(pm.get_image(wn, [10, 10, 20, 20])[5, 5].tolist() == [204, 51, 255], 'in any memory layout or float type')
usage = ("linearize takes the display's gamma (one value or [r g b], each 0.05 to 20), an (N, 3) table "
         'of display values 0..1 with N from 2 to 4096, or None to turn it off.')
for spec in (0, 25, [2, 2], table * 2, table[:, :2], table[:1], 'abc', float('nan')):
    raises(pm.linearize, wn, spec, message=usage)
raises(core.set_gamma_table, table.T, message='The gamma table must be Nx3 real doubles, N from 2 to 4096.')
raises(core.set_gamma, 0, 1, 1, message='Gamma exponents must be 0.05 to 20.')
check(pm.linearize(wn, None).shape == (5, 3) and pm.linearize(wn) is None, 'linearize(w, None) turns it off')

r, ascent = pm.text_bounds(wn, 'abcd', 20)
check(r.tolist() == [0, 0, 50, 26] and ascent == 19, 'text_bounds returns [0 0 width height] and the ascent')
check(pm.text_bounds(wn, 'ü你', 20)[0][2] == 26, 'two characters of UTF-8 are two characters wide')
where, _ = pm.draw_text(wn, '^_', 300, 200, [255, 255, 0], 50); pm.flip(wn)
check(where.tolist() == [300, 200, 362, 262], 'draw_text returns where it drew')
box = pm.get_image(wn, where)
ink = (box == [255, 255, 0]).all(axis=2)
up, down = np.nonzero(ink[:31])[1], np.nonzero(ink[31:])[1]
check(up.size and down.size and up.max() < down.min(), 'text reads back upright, in its colour')
where, _ = pm.draw_text(wn, 'abcd'); pm.flip(wn)
check(where.tolist() == [375, 287, 425, 313], 'draw_text centres by default, at a thirtieth of the height')
check(pm.draw_text(wn, 'abcd', 7.5)[0].tolist() == [8, 287, 58, 313], 'x alone leaves y centred; positions round to pixels')
pm.flip(wn)
where, _ = pm.draw_text(wn, 'ab\n\nabcdef', None, None, 255, 20); pm.flip(wn)
check(where.tolist() == [363, 261, 437, 339], 'lines are 1.3 sizes apart, each centred, the block centred')
check(pm.text_bounds(wn, 'ab\nabcdef', 20)[0].tolist() == [0, 0, 74, 52], 'text_bounds of two lines')
where, _ = pm.draw_text(wn, 'aa bbb cc dddd', 0, 0, 255, 20, None, 100); pm.flip(wn)
check(where.tolist() == [0, 0, 86, 52], 'a wrap width breaks lines between words')
raises(pm.draw_text, wn, 'a', 0, 0, 255, 20, None, 0, message='The wrap width must be a positive number of pixels.')
raises(pm.draw_text, wn, '\n', message='The text must not be empty.')
raises(pm.draw_text, wn, 5, message='The text must be a string.')
raises(pm.draw_text, wn, 'a', 0, 0, 255, -1, message='The text size must be a positive number of pixels.')
raises(pm.draw_text, wn, 'a', 0, 0, 255, 2, message='Text size must be 4 to 2048 pixels.')
raises(pm.draw_text, wn, 'a', float('nan'), message='The text position must be finite, in window pixels; None centres it.')
raises(pm.draw_text, wn, '', message='The text must not be empty.')
raises(pm.text_bounds, wn, 'a', 20, 7, message='The font must be a name.')
raises(core.draw_text, 'a', '', 20, 0, 0, (1, 1, 1), message='Text colour must be four real numbers, RGBA.')
raises(core.text_bounds, b'a', '', 20, message='Text must be a string.')

k = pm.link_info(wn)
check(list(k) == ['lanes', 'laneGbps', 'payloadGbps', 'pixelGbps', 'compressed'] and np.isnan(k['lanes'])
      and np.isnan(k['compressed']) and abs(k['pixelGbps'] - 800 * 600 * 24 * 60 / 1e9) < 1e-9, 'an unidentified link is nan')
d = pm.diagnostic(wn)['summary']
check(d['bitDepth'] == 8 and d['blendFunction'] == 'alpha', 'diagnostic reports the bit depth and blend mode')
pm.close(wn)

import contextlib, io


def opened(**env):
    """What open_window prints with these environment settings, and the link it then reports."""
    os.environ.update(env)
    try:
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            w, _, _ = pm.open_window(0)
        k = pm.link_info(w)
        pm.close(w)
        return said.getvalue(), k
    finally:
        for name in env:
            del os.environ[name]


said, k = opened(PM_MOCK_LINK='4,5.4')
check('DSC' not in said and k['lanes'] == 4 and abs(k['payloadGbps'] - 17.28) < 1e-9 and k['compressed'] == 0,
      '800x600 fits an HBR2 link: no banner')
said, k = opened(PM_MOCK_LINK='4,5.4', PM_MOCK_DISPLAY='6016x3384@60')
check('needs 29.3 Gbit/s and the display link carries 17.3' in said and k['compressed'] == 1,
      'a 6K picture on an HBR2 link is reported as compressed')

# --- ten bits per channel --------------------------------------------------------------------
wt, _, _ = pm.open_window(0, [51, 102, 153], readback=True, bit_depth=10)
pm.fill_rect(wt, [255, 0, 0], [10, 20, 110, 70]); pm.flip(wt)
shot = pm.get_image(wt)
check(shot.dtype == np.uint16 and shot.shape == (600, 800, 3) and shot[0, 0].tolist() == [205, 409, 614]
      and shot[45, 60].tolist() == [1023, 0, 0], 'a 10-bit frame is uint16 0..1023, RGB')
check(np.array_equal(pm.get_image(wt, [5, 15, 120, 80]), shot[15:80, 5:120]), 'and a rect of it is that part')
check(abs(pm.link_info(wt)['pixelGbps'] - 800 * 600 * 30 * 60 / 1e9) < 1e-9 and pm.diagnostic(wt)['summary']['bitDepth'] == 10,
      'a 10-bit window needs 30 bits per pixel')
pm.close(wt)
wt, _, _ = pm.open_window(0, bit_depth=10)
raises(pm.get_image, wt, message='GetImage requires a window opened with readback.')
pm.close(wt)

# --- offscreen windows, polygons, the clip rect -------------------------------------------------
wo, _, _ = pm.open_window(0, [0, 0, 0], readback=True)
tex = pm.make_texture(wo, np.full((4, 4), 255, np.uint8))
check(tex != wo, 'a texture handle is never the window handle')
off, orect = pm.open_offscreen_window(wo, [255, 0, 0, 0], [0, 0, 40, 20])
check(orect.tolist() == [0, 0, 40, 20] and pm.rect(off).tolist() == [0, 0, 40, 20] and pm.window_size(off) == (40, 20),
      'an offscreen window has its own rect')
pm.fill_rect(off, [0, 255, 0], [10, 5, 30, 15])              # opaque green on transparent red
pm.fill_rect(wo, [0, 0, 255], [100, 100, 200, 200])         # the window is the target again
pm.draw_texture(wo, off, None, [120, 140, 160, 160], 0, 0)
pm.flip(wo); shot = pm.get_image(wo)
check(shot[150, 140].tolist() == [0, 255, 0] and shot[142, 122].tolist() == [0, 0, 255] and shot[150, 100].tolist() == [0, 0, 255],
      'what was drawn offscreen is drawn where the offscreen window is, and its transparent part shows what is under it')
pm.draw_texture(wo, off, None, [300, 300, 340, 320], 0, 0); pm.flip(wo)
check(pm.get_image(wo)[310, 320].tolist() == [0, 255, 0], 'an offscreen window keeps what was drawn into it')
pm.fill_rect(off, [255, 255, 255], [0, 0, 5, 5])             # more is added to it
pm.flip(wo)                                                  # a flip renders what waits for the target
pm.draw_texture(wo, off, None, [300, 300, 340, 320], 0, 0); pm.flip(wo); shot = pm.get_image(wo)
check(shot[302, 302].tolist() == [255, 255, 255] and shot[310, 320].tolist() == [0, 255, 0], 'draws into it accumulate')
pm.blend_function(off, 'copy'); pm.fill_rect(off, [0, 0, 0, 0]); pm.blend_function(off, 'alpha')
pm.fill_rect(wo, 128, [300, 300, 340, 320]); pm.draw_texture(wo, off, None, [300, 300, 340, 320], 0, 0)
pm.flip(wo)
check(pm.get_image(wo)[310, 320].tolist() == [128, 128, 128], "'copy' clears an offscreen window to transparent")
pm.draw_texture(wo, off, None, [300, 300, 340, 320], 0, 0)   # the window has a draw of it waiting
raises(pm.fill_rect, off, 255, message='The window has draws of that offscreen window waiting; Flip before drawing into it again.')
check(pm._S['target'] == 0, 'a refused change of target leaves the window as the target')
pm.flip(wo); pm.fill_rect(off, [0, 0, 0, 0])                 # after the flip it can be drawn into again
pm.draw_text(off, '^_', 0, 0, 255, 10)
raises(pm.draw_texture, off, off, message='An offscreen window cannot be drawn into itself.')
raises(pm.update_texture, wo, off, np.zeros((20, 40)), message='That is an offscreen window; draw into it instead.')
raises(pm.update_texture, wo, off, np.zeros((2, 2)), [0, 0, 2, 2], message='That is an offscreen window; draw into it instead.')
raises(core.set_target, tex, message='That texture is not an offscreen window.')
raises(pm.open_offscreen_window, wo, 0, [0, 0, 0, 5], message='An offscreen window is 1 to 16384 whole pixels each way.')
raises(pm.open_offscreen_window, wo, 0, [0, 0, 4.5, 5], message='An offscreen window is 1 to 16384 whole pixels each way.')
raises(pm.fill_rect, 12345, 0, message='fill_rect requires the window handle from open_window, or one from open_offscreen_window.')
pm.fill_rect(off, 255); pm.close(off)
check(pm._S['target'] == 0 and off not in pm._S['offscreen'] and off not in pm._S['textures'], 'closing the target returns to the window')
raises(pm.fill_rect, off, 0)
pm.flip(wo)

pm.fill_poly(wo, [255, 0, 0], [[100, 100], [200, 100], [100, 200]])            # a right triangle
pm.frame_poly(wo, [0, 255, 0], np.array([[300, 400, 400, 300], [100, 100, 200, 200]]), 4)   # 2xN: a square outline
pm.flip(wo); shot = pm.get_image(wo)
check(shot[120, 120].tolist() == [255, 0, 0] and shot[190, 190].tolist() == [0, 0, 0], 'a polygon fills its inside only')
check(shot[100, 350].tolist() == [0, 255, 0] and shot[150, 350].tolist() == [0, 0, 0] and shot[150, 300].tolist() == [0, 255, 0],
      'frame_poly draws the outline, not the inside')
points = 'The points must be (N, 2), one [x, y] per row, with at least three.'
raises(pm.fill_poly, wo, 255, [[1, 2], [3, 4]], message=points)
raises(pm.fill_poly, wo, 255, [1, 2, 3, 4, 5, 6], message=points)
raises(pm.fill_poly, wo, 255, [[1, 2], [3, np.nan], [5, 6]], message=points)
raises(pm.frame_poly, wo, 255, [[1, 2], [3, 4], [5, 6]], 0, message='Pen width must be positive.')
raises(core.draw_polygon, np.zeros((3, 3)), (1, 1, 1, 1), 0, message='A polygon is 3 to 4096 points, as Nx2 real doubles.')
raises(core.draw_polygon, np.zeros((3, 2)), (1, 1, 1, 1), -1, message='The polygon pen width must be 0 (filled) to 1024 pixels.')
raises(core.draw_polygon, np.zeros((3, 2)), (1, 1, 1, 2), 0, message='Polygon colour components run 0 to 1.')
poly = np.asfortranarray(np.array([[100.0, 100], [200, 100], [100, 200]]))[:, ::-1][:, ::-1]
core.draw_polygon(poly, (1, 1, 1, 1), 0); pm.flip(wo)
check(pm.get_image(wo)[120, 120].tolist() == [255, 255, 255], 'points are read in any memory layout')

check(pm.clip(wo) is None and pm.clip(wo, [110, 120, 150, 160]) is None, 'clip returns the old rect')
pm.fill_rect(wo, [255, 255, 0])                            # the whole window, clipped
check(pm.clip(wo, None).tolist() == [110, 120, 150, 160] and pm.clip(wo) is None, 'clip(w, None) ends it')
pm.fill_rect(wo, [0, 0, 255], [0, 0, 10, 10])              # queued after the clip ended
pm.flip(wo); shot = pm.get_image(wo)
check((shot[120:160, 110:150] == [255, 255, 0]).all() and shot[119, 110].tolist() == [0, 0, 0] and shot[160, 149].tolist() == [0, 0, 0]
      and shot[120, 109].tolist() == [0, 0, 0] and shot[5, 5].tolist() == [0, 0, 255], 'the clip belongs to each draw as it is queued')
pm.clip(wo, [700, 500, 900, 700]); pm.fill_rect(wo, 255); pm.clip(wo, None); pm.flip(wo); shot = pm.get_image(wo)
check((shot[500:, 700:] == 255).all() and (shot[499, 700:] == 0).all(), 'a clip rect is cut to the window')
bad = 'The clip rect must be [left top right bottom] in whole pixels.'
for r in ([1, 2, 3], [10, 10, 10, 20], [0.5, 0, 10, 10], 'abcd'):
    raises(pm.clip, wo, r, message=bad)

# --- frames queued ahead ----------------------------------------------------------------------------
t0 = pm.get_secs() + 0.1
tokens = []
for k in range(5):
    pm.fill_rect(wo, 40 * (k + 1), [0, 0, 50, 50])
    token, pending, capacity = pm.queue_flip(wo, t0 + k * ifi)
    tokens.append(token)
check(pm.get_secs() < t0 and pending == 5 and capacity == 64, 'queue_flip returns at once, with what is waiting and the capacity')
check((pm.get_image(wo, [0, 0, 50, 50]) == 200).all(), 'a queued frame is rendered when it is queued')
raises(pm.queue_flip, wo, t0, message='Queued frames must be given in order of time.')
check(pm.queue_results(wo, False).shape == (0, 4), 'nothing is reported before it is shown')
frames = pm.queue_results(wo)
check(frames.shape == (5, 4) and frames[:, 3].tolist() == tokens and (frames[:, 2] == 0).all() and
      (frames[:, 1] >= frames[:, 0] - 1e-9).all() and np.allclose(np.diff(frames[:, 1]), ifi), 'five frames, one refresh apart, none early')
check(pm.queue_results(wo).shape == (0, 4), 'each frame is reported once')
vbl = pm.flip(wo)[0]
check(vbl > frames[-1, 1], 'a flip comes after the frames that were queued')
t0 = pm.get_secs() + 0.5
for k in range(3):
    pm.queue_flip(wo, t0 + k * ifi)
check(pm.queue_cancel(wo) == 3, 'queue_cancel abandons frames not yet handed over')
frames = pm.queue_results(wo)
check((frames[:, 2] == 5).all() and np.isnan(frames[:, 1]).all() and pm.get_secs() < t0, 'cancelled frames are reported as cancelled, at once')
raises(pm.queue_flip, wo, 0, message='The presentation time must be a positive GetSecs timestamp.')
raises(core.queue_flip, float('nan'), message='presentation time must be finite.')
raises(core.queue_results, 2, message='wait must be a nonnegative integer in range.')
pm.close(wo)

# --- input events ------------------------------------------------------------------------------------
os.environ['PM_MOCK_MOUSE'] = '3,0,0'
try:
    wm, _, _ = pm.open_window(0)
    events, dropped = pm.mouse_events(wm)
    check(events.shape == (0, 5) and dropped == 0, 'the first mouse_events starts listening and returns nothing')
    times = [pm.flip(wm)[0] for _ in range(5)]
    events, dropped = pm.mouse_events(wm)
    check(events.shape == (1, 5) and events[0].tolist() == [times[2], 1, 1, 400, 300], 'a press is reported with its own time and place')
    check(pm.mouse_events(wm)[0].shape == (0, 5), 'and once')
    touches, lost = pm.touch_events(wm)
    check(touches.shape == (3, 5) and lost == 0 and touches[:, 1].tolist() == [1, 1, 1] and
          touches[:, 2].tolist() == [0, 1, 2] and touches[0, 0] == times[2] and
          touches[:, 3].tolist() == [400, 405, 410] and touches[:, 4].tolist() == [300, 300, 300],
          'a finger going down, moving and lifting is reported with its times and places')
    check(pm.touch_events(wm)[0].shape == (0, 5), 'and once')
    ended = []
    worker = pm.start(lambda: [pm.flip(wm) for _ in range(1000)], done=lambda result, error: ended.append(error))
    pm.stop()
    worker.join()
    check(len(ended) == 1 and isinstance(ended[0], KeyboardInterrupt), 'stop ends a started experiment at its next frame')
    pm.start(lambda: None).join()
    check(np.isfinite(pm.flip(wm)[0]), 'and the next start clears the stop')
    # The main thread waits a moment for the worker's call, then is refused: a
    # call that holds the engine longer (a Flip timed 0.5 s ahead) may itself be
    # waiting for the main thread.
    worker = pm.start(lambda: pm.flip(wm, pm.get_secs() + 0.5))
    time.sleep(0.1)
    t0 = time.perf_counter()
    e = raises(pm.flip, wm)
    waited = time.perf_counter() - t0
    worker.join()
    check(str(e).startswith('PsychMetal is in use on another thread') and 0.04 < waited < 0.3,
          'the main thread waits a moment, then is refused, while a started experiment holds the engine')
    pm.close(wm)
    gate = threading.Event()
    worker = pm.start(lambda: (pm.open_window(0), gate.wait()))
    raises(pm.start, lambda: None, message='An experiment is already running: wait for it to end.')
    gate.set()
    worker.join()
    raises(pm.flip, wm, message='PsychMetal is not open.')
    wm, _, _ = pm.open_window(0)
    pm.close(wm)
finally:
    del os.environ['PM_MOCK_MOUSE']
pm.kb_queue_create(); pm.kb_queue_start()
st = pm.kb_queue_status()
check(st['eventTimestamps'] is False and st['eventStamped'] == 0 and st['pollStamped'] == 0 and st['maxEventDelayMs'] == 0,
      'kb_queue_status says whether key times are event times')
pm.kb_queue_release()

# --- an experiment, both threading modes -----------------------------------------------------
def experiment(screen=0, seconds=60):
    w, rect, ifi = pm.open_window(screen)
    try:
        for _ in range(round(seconds / ifi)):
            if pm.get_mouse(w)[2].any():
                break
            pm.fill_rect(w, 128)
            pm.flip(w)
    finally:
        pm.close(w)


os.environ['PM_MOCK_DISPLAY'] = '1920x1080@240'
os.environ['PM_MOCK_MOUSE'] = '120,7,-3'
pm.run(experiment)
h = core.diagnostic()[0]
check(h.shape[0] == 120, f'main thread: ran until the click ({h.shape[0]} frames)')
os.environ['PM_MOCK_MOUSE'] = '60,-5,2'
pm.run(experiment, threaded=True)
check(core.diagnostic()[0].shape[0] == 60, 'threaded: ran until the click')
e = raises(pm.run, experiment, 5, threaded=True, id='PsychMetal:Screen')
check(pm._S is None, 'a worker exception reaches the main thread with its id, window state cleared')

# --- Ctrl-C in threaded mode closes the window --------------------------------------------------
os.environ['PM_MOCK_MOUSE'] = '-1,1,0'
threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
raises(pm.run, experiment, threaded=True, exc=KeyboardInterrupt)
check(pm._S is None and core.diagnostic()[0].shape[0] > 10, 'Ctrl-C stopped the threaded run and closed the window')

print(f'PASS: {passed} checks of the psychmetal package through the Python front end.')

# Captured native timeline through the real binding and scripted presenter.
w,_,ifi_tl=pm.open_window()
pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
before=pm._S['flip_count']
r=pm.play_timeline(w,6,[[0,1,1,4,360,0]])
check(r['submitted']==6 and not r['cancelled'] and r['lastToken']-r['firstToken']==5,'timeline native result')
check(r['shown']==6 and r['late']==0 and r['lateRefreshes']==0 and np.isnan(r['firstLateSample']) and
      abs(r['meanSampleMs']-1000*ifi_tl)<1e-6,'timeline reports what the display showed')
check(pm._S['flip_count']==before+6,'timeline updates wrapper counters')
raises(pm.play_timeline,w,0)
raises(pm.play_timeline,w,2,[[0,1,1,3,360,0]])
raises(pm.play_timeline,w,2,np.ones((2,5)))
# A cancellation made while nothing plays is not lost: it ends the next playback
# at once, and is then spent. Python's start and run clear it.
core.cancel_timeline()
r=pm.play_timeline(w,2)
check(r['submitted']==0 and r['cancelled'],'a cancellation made just before playback ends it')
pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
r=pm.play_timeline(w,2)
check(r['submitted']==2 and not r['cancelled'],'and is spent by it')
core.cancel_timeline();core.cancel_timeline(False)
pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
r=pm.play_timeline(w,2)
check(r['submitted']==2 and not r['cancelled'],'cancel_timeline(False) clears a request')
# The binding releases the GIL and cancellation bypasses its engine mutex.
def cancel_later():
    time.sleep(.1)
    core.cancel_timeline()
t=threading.Thread(target=cancel_later);t.start()
r=pm.play_timeline(w,120)
t.join()
check(r['cancelled'] and 0<r['submitted']<120,'concurrent native cancellation')
pm.close(w)
print('PASS: timeline front-end result/counters, rejection and GIL-free cancellation.')

# Reusable analytic GPU masks: constructor validation and binding contracts.
for kind in ('ellipse','gaussian','annulus','raised_cosine'):
    mask=pm.make_mask(kind)
    check(isinstance(mask,tuple) and len(mask)==8,'immutable '+kind+' mask')
raises(pm.make_mask,'unknown')
raises(pm.make_mask,'annulus',inner=1)
raises(pm.make_mask,'annulus',inner=.8,edge=.11)
check(pm.make_mask('annulus',inner=.8,edge=.1)[4]==.1,'annulus touching fade bounds')
raises(pm.make_mask,'raised_cosine',edge=0)
raises(pm.make_mask,'gaussian',sigma=0)
raises(pm.make_mask,'ellipse',center=[1])
raises(pm.make_mask,'ellipse',center=[np.nan,0])
raises(pm.make_mask,'ellipse',invert=2)
raises(pm.make_mask,'gaussian',radius=.5) # reject irrelevant options
w,_,_=pm.open_window()
s=pm.make_stimulus('noise',grain=1)
m=pm.make_mask('annulus',inner=.4,edge=.1)
pm.draw_stimulus(w,s,[0,0,100,100],m)
pm.flip(w)
texture=pm.make_texture(w,np.ones((4,4),dtype=np.float32))
pm.draw_stimulus(w,s,[0,0,200,200],texture,coverage=m)
pm.close_texture(w,texture)
pm.flip(w)
raises(pm.draw_stimulus,w,s,[0,0,100,100],m,coverage=m)
raises(core.draw_stimulus,np.array(s),np.array([0.,0.,10.,10.]),0,np.zeros(7))
pm.close(w)
print('PASS: analytic mask recipes, bounds, unsupported options, image-mask combination and close-after-draw.')

# Masked still images: bindings only (real native ownership/shader tests separate).
w,_,_=pm.open_window()
t=pm.make_texture(w,np.ones((8,12,4),dtype=np.float32))
m=pm.make_texture(w,np.ones((4,4),dtype=np.float32))
a=pm.make_mask('raised_cosine',edge=.2)
pm.draw_masked_texture(w,t,a,src_rect=[2,1,10,7],dst_rect=[0,0,100,80],angle=30,global_alpha=128)
pm.draw_masked_texture(w,t,m,coverage=a)
raises(pm.draw_masked_texture,w,t,a,coverage=a)
raises(pm.draw_masked_texture,w,t,t) # colour image cannot be a coverage mask
for opts in ({'src_rect':[-1,0,10,8]},{'src_rect':[0,0,13,8]}, {'src_rect':[4,0,4,8]},
             {'dst_rect':[0,0,0,10]}, {'angle':np.inf}, {'filter_mode':2}, {'global_alpha':256}):
    raises(pm.draw_masked_texture,w,t,a,**opts)
raises(core.draw_masked_texture,t,np.zeros(13),0)
pm.close_texture(w,t);pm.close_texture(w,m);pm.flip(w)
pm.close(w)
print('PASS: masked still-image binding contracts, cropping, rotation, opacity, combined masks and rejection.')

w,_,_=pm.open_window()
shader=pm.create_shader(w,'float4 psychmetal_main(float2 pixel,float2 uv,constant float4* p){return p[0];}')
pm.draw_shader(w,shader,[.5,.25,.75,1],[0,0,100,100],pm.make_mask('gaussian'))
raises(pm.draw_shader,w,shader,[np.nan])
raises(pm.draw_shader,w,shader,np.zeros(17))
raises(pm.create_shader,w,'bad\0source')
raises(core.create_shader,'float4 psychmetal_main(float2 pixel,float2 uv,constant float4* p){return p[0];}\0suffix')
pm.close_shader(w,shader);pm.flip(w)
raises(pm.draw_shader,w,shader)
raises(pm.close_shader,w,shader)
raises(pm.update_timeline,[[0,0,.5]])
pm.close(w)
w,_,_=pm.open_window();pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
updates=[]
def change_later():
    import time
    time.sleep(.04)
    pm.update_timeline([[0,0,.25],[0,2,20]])
    updates.append(True)
t=threading.Thread(target=change_later);t.start();pm.play_timeline(w,20);t.join()
check(updates==[True],'live timeline update bypasses playback mutex')
# A controller thread reads input and waits while the timeline plays.
pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
steps=[]
def steer():
    time.sleep(.05)
    for _ in range(5):
        t0=time.perf_counter()
        pm.get_mouse(w);pm.mouse_events(w);pm.touch_events(w);pm.kb_check();pm.wait_secs(.005)
        steps.append(time.perf_counter()-t0)
        pm.update_timeline([[0,0,.5]])
t=threading.Thread(target=steer);t.start();r=pm.play_timeline(w,40);t.join()
check(len(steps)==5 and max(steps)<.1 and r['submitted']==40,'input and waits run beside a playing timeline')
# An experiment on the main thread is not stopped by a helper thread reading input.
done=threading.Event()
def read_until_done():
    while not done.is_set():
        pm.get_mouse(w);pm.kb_check();pm.wait_secs(.001)
t=threading.Thread(target=read_until_done);t.start()
try:
    for _ in range(30):
        pm.fill_rect(w,[10,20,30]);pm.flip(w)
finally:
    done.set();t.join()
check(True,'the main thread draws and flips while a helper reads input')
pm.close(w)
print('PASS: custom shader binding contracts, expiration, parameter bounds, raw NUL rejection and concurrent timeline control.')

# Optional keyframes cross the real Python binding.
w,_,_=pm.open_window()
pm.draw_stimulus(w,pm.make_stimulus('grating'),[0,0,100,100])
raises(pm.play_timeline,w,3,None,[[0,1,2,0],[0,1,1,90]])
raises(pm.play_timeline,w,3,[[0,1,1,4,360,0]],[[0,1,0,90]])
raises(pm.play_timeline,w,3,None,[[0,0,0,2]])
raises(pm.play_timeline,w,3,None,np.ones((2,3)))
r=pm.play_timeline(w,3,keyframes=[[0,1,0,0],[0,1,2,180]])
check(r['submitted']==3,'keyframe playback binding')
pm.close(w)
print('PASS: keyframe binding, range/order and periodic collision checks.')

# Input readers share playback access, but serialize their own native counters.
os.environ['PM_MOCK_INPUT_SERIAL']='1'
barrier=threading.Barrier(3);errors=[]
def concurrent_reader():
    barrier.wait()
    try:
        for _ in range(30):pm.kb_check()
    except BaseException as error:errors.append(error)
threads=[threading.Thread(target=concurrent_reader) for _ in range(2)]
for t in threads:t.start()
barrier.wait()
for t in threads:t.join()
del os.environ['PM_MOCK_INPUT_SERIAL']
check(not errors,'concurrent input callers serialize native reader state')
print('PASS: input readers do not race native counters or listener setup.')
