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
check(pm.version() == '0.5.0' and core.version() == '0.5.0', 'versions agree')

# --- window, rect, time -------------------------------------------------------------
w, rect, ifi = pm.open_window(0, [0, 0, 0])
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
tok = core.queue_frame()
check(core.wait_scheduled(tok)[2] is True, 'queue_frame / wait_scheduled')
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
check(h.shape[1] == 17 and len(s) == 60, 'raw diagnostic: 17 history columns, 60 summary fields')
check(list(s)[:3] == ['confirmedPresentations', 'missingPresentedTimes', 'lastTargetErrorMs'], 'summary field order')
check(d['summary']['flips'] == 8 and np.isfinite(d['summary']['measuredRefreshHz']), 'diagnostic summary and refresh fit')
check(set(['flipNumber', 'actualTimestamp', 'pipelineLeadMs', 'startup']) <= set(d), 'diagnostic fields')

# --- input ------------------------------------------------------------------------------------
x, y, buttons = pm.get_mouse(w)
check(buttons.dtype == bool and buttons.shape == (3,), 'get_mouse buttons are bool[3]')
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
raises(pm.flip, w, message='PsychMetal is not open.')
m = pm.resolutions(0)
check(len(m) == 2 and m[0]['width'] == 800, 'resolutions lists modes as dicts')
check(pm.resolution(0, 1024, 768)['width'] == 800, 'resolution sets and returns the old mode')
raises(core.set_mode, 0, 640, 480, message='No display mode is 640 x 480 points on that display.', id='PsychMetal:Mode')
core.prepare_app()
raises(core.open_session, 3, 3, 1, 1, 1, message='Screen index 3 is out of range; 1 display(s) are active.', id='PsychMetal:Screen')
raises(core.open_session, 0, 1, 1, 1, 1, message='Drawable count must be 2 or 3.')
raises(core.open_session, 0, 4, 1, 1, 1, message='maximum drawable count must be a nonnegative integer in range.')
raises(core.open_session, 0.5, 3, 1, 1, 1, message='screen index must be a non-negative integer, or -1 for the last display.')
raises(core.open_session, 0, 3, 2, 1, 1, message='wait for confirmation must be a nonnegative integer in range.')

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
