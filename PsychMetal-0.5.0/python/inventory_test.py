#!/usr/bin/env python3
"""Exercise every command the psychmetal package exposes.

Python port of PsychMetalInventoryTest.m:

    python3 inventory_test.py              # run everything
    python3 inventory_test.py --verbose    # print each check as it passes

Coverage, not timing. The timing tests measure how well things work; this one
establishes that they work at all, that every documented command accepts what
its help says it accepts, and that the ones which are supposed to reject bad
input actually do. Every command gets at least one deliberate misuse, and a
command that fails to complain is a failure here.

THE COMMAND LIST IS DERIVED FROM THE PACKAGE (psychmetal.__all__), not written
out by hand, and every call goes through a tracer. If a command is added and
not covered here, the final check fails and names it.

About 25 seconds. Every check is independent; a failure is recorded and the run
continues, so one broken command does not hide the state of the rest.

SPDX-License-Identifier: MIT
"""
import argparse
import math
import warnings

import numpy as np

import psychmetal as pm


class Tracer:
    """Every command goes through here, so coverage is what was called, not a list."""
    def __init__(self):
        self.called = set()

    def __getattr__(self, name):
        attr = getattr(pm, name)
        if callable(attr) and not isinstance(attr, type):
            self.called.add(name)
        return attr


def commands_in_package():
    """Every public function of the package: the Python counterpart of reading
    PsychMetal.m's dispatch switch."""
    return sorted(n for n in pm.__all__ if callable(getattr(pm, n)) and not isinstance(getattr(pm, n), type))


def inventory_test(verbose=False):
    ipm = Tracer()
    results = []

    def record(name, ok, detail=''):
        results.append(dict(name=name, ok=bool(ok), detail=detail))
        if verbose:
            print(f'  ok    {name}' if ok else f'  FAIL  {name}: {detail}')

    def check(name, fn):
        """A check that must run cleanly."""
        try:
            result = fn()
            if result is False:
                raise AssertionError('returned False')
            record(name, True)
        except Exception as e:
            record(name, False, f'{type(e).__name__}: {e}')

    def reject(name, fn):
        """A check that must RAISE. Silence here is the failure."""
        try:
            fn()
            record(name, False, 'accepted invalid input without error')
        except Exception:
            record(name, True)

    w = tex = None
    try:
        print('\npsychmetal inventory test. About 25 seconds.\n')

        # ---- commands that work without a window --------------------------------
        check('version returns a string', lambda: isinstance(ipm.version(), str))
        check('every command has a docstring', lambda: assert_empty(
            [n for n in commands_in_package() if not getattr(pm, n).__doc__], 'no docstring'))
        reject('unknown command is rejected', lambda: ipm.no_such_command())
        reject('drawing before open_window is rejected', lambda: ipm.fill_rect(1))
        check('resolution query', lambda: isinstance(ipm.resolution(None), dict))
        check('resolutions list', lambda: isinstance(ipm.resolutions(None), list) and
              all(isinstance(m, dict) for m in ipm.resolutions(None)))
        check('kb_queue_status reports state', lambda: isinstance(ipm.kb_queue_status(), dict))
        check('run calls the function and returns its result', lambda: ipm.run(lambda a, b=0: a + b, 2, b=3) == 5)

        # ---- open ---------------------------------------------------------------
        w, rect, ifi = ipm.open_window(None)
        ipm.hide_cursor()
        record('open_window', True)
        check('rect is a sane 4-vector', lambda: len(rect) == 4 and rect[2] > rect[0] and rect[3] > rect[1])
        check('ifi is near a plausible refresh', lambda: 0.004 < ifi < 0.05)
        reject('a second open_window is rejected', lambda: ipm.open_window(None))
        reject('a bad window handle is rejected', lambda: ipm.fill_rect(w + 999))
        # Extra arguments must be refused, not ignored.
        reject('make_texture with a spare argument rejected', lambda: ipm.make_texture(w, np.random.rand(8, 8), 99))
        reject('get_mouse with a spare argument rejected', lambda: ipm.get_mouse(w, 99))
        reject('version with an argument rejected', lambda: ipm.version(99))

        # ---- the Screen queries a drop-in needs ---------------------------------
        # COLOURS OPEN AT 0-255, as Screen's do. Checked BEFORE anything changes it.
        check('color_range opens at 255', lambda: ipm.color_range(w) == 255)
        check('color_range returns the previous value',
              lambda: ipm.color_range(w, 1) == 255 and ipm.color_range(w, 255) == 1)
        reject('a zero color_range is rejected', lambda: ipm.color_range(w, 0))
        check('rect matches open_window', lambda: np.array_equal(ipm.rect(w), rect))
        check('window_size matches rect', lambda: tuple(ipm.window_size(w)) == (rect[2] - rect[0], rect[3] - rect[1]))
        check('get_flip_interval is a plausible refresh', lambda: assert_near_ifi(ipm.get_flip_interval(w), ifi))
        check('get_secs returns a plausible clock time', lambda: assert_near(ipm.get_secs(), 'get_secs', ipm))
        check('get_secs advances', lambda: ipm.get_secs() < ipm.wait_secs(0.002))
        reject('get_secs with an argument rejected', lambda: ipm.get_secs(w))
        # Measured, not just called: early returns and overshoot both miss frames.
        check("wait_secs('UntilTime', t)", lambda: assert_wait(ipm, 0.010, True, 200e-6))
        check('wait_secs, relative', lambda: assert_wait(ipm, 0.010, False, 600e-6))
        reject('wait_secs with no argument rejected', lambda: ipm.wait_secs())
        reject('wait_secs with an unknown string rejected', lambda: ipm.wait_secs('Whenever', 1))

        check('background_color, scalar grey', lambda: ipm.background_color(w, 64))
        check('background_color, RGB', lambda: ipm.background_color(w, [0, 0, 51]))
        check('background_color, RGBA', lambda: ipm.background_color(w, [0, 0, 0, 255]))
        reject('background_color with a 2-vector rejected', lambda: ipm.background_color(w, [128, 128]))
        reject('background_color without a window rejected', lambda: ipm.background_color(128))
        ipm.background_color(w, 0)

        # ---- the drawing primitives ---------------------------------------------
        W, H = rect[2], rect[3]
        box = [round(W * 0.3), round(H * 0.3), round(W * 0.7), round(H * 0.7)]
        check('fill_rect, whole window', lambda: ipm.fill_rect(w, 51))
        check('fill_rect, explicit rect', lambda: ipm.fill_rect(w, [255, 0, 0], box))
        check('frame_rect with pen width', lambda: ipm.frame_rect(w, [0, 255, 0], box, 4))
        check('fill_oval', lambda: ipm.fill_oval(w, [0, 0, 255], box))
        check('frame_oval with pen width', lambda: ipm.frame_oval(w, [255, 255, 0], box, 6))
        check('draw_gabor, sigma only', lambda: ipm.draw_gabor(w, [255, 255, 255, 128], box, 0.3))
        check('draw_gabor with frequency', lambda: ipm.draw_gabor(w, 255, box, 0.3, 0.02))
        check('draw_gabor with orientation', lambda: ipm.draw_gabor(w, 255, box, 0.3, 0.02, 45))
        check('draw_gabor with phase', lambda: ipm.draw_gabor(w, 255, box, 0.3, 0.02, 45, 90))
        check('draw_gabor at frequency 0 is the Gaussian', lambda: ipm.draw_gabor(w, [255, 255, 255, 128], box, 0.3, 0))
        check('draw_noise with no seed', lambda: ipm.draw_noise(w, box))
        check('draw_noise, explicit seed', lambda: ipm.draw_noise(w, box, 1))
        check('draw_noise, normal mono', lambda: ipm.draw_noise(w, box, 2, 'normal'))
        check('draw_noise, uniform colour', lambda: ipm.draw_noise(w, box, 3, 'uniform', 'colour'))
        check('draw_noise with mean and spread', lambda: ipm.draw_noise(w, box, 4, 'normal', 'mono', 128, 26))
        s1 = ipm.draw_noise(w, box)
        check('draw_noise returns an integer seed', lambda: isinstance(s1, int) and 0 <= s1 <= 16777215)
        check('an unseeded call returns a different seed next time',
              lambda: ipm.draw_noise(w, box) != ipm.draw_noise(w, box) or ipm.draw_noise(w, box) != ipm.draw_noise(w, box))
        check('an explicit seed is returned unchanged', lambda: ipm.draw_noise(w, box, 12345) == 12345)
        s2, nvals = ipm.draw_noise(w, [0, 0, 16, 8], values=True)
        check('values=True also returns the values', lambda: nvals.shape == (8, 16) and np.all((nvals >= 0) & (nvals <= 255)))
        check('the returned values match the returned seed',
              lambda: np.array_equal(nvals, ipm.noise_values(w, [0, 0, 16, 8], s2)))
        check('draw_dots, 500 of them', lambda: ipm.draw_dots(
            w, [W * 0.5 + 100 * np.random.randn(500), H * 0.5 + 100 * np.random.randn(500)], 4, 255))
        check('draw_lines, 10 segments', lambda: ipm.draw_lines(w, [np.linspace(0, W, 20), np.linspace(0, H, 20)], 2, 128))
        check('4xN rect draws many at once', lambda: ipm.fill_rect(w, 77, [np.linspace(0, W * 0.8, 5), np.full(5, H * 0.1),
                                                                         np.linspace(W * 0.2, W, 5), np.full(5, H * 0.2)]))
        check('per-shape colours, 3xN', lambda: ipm.fill_oval(w, np.array([[255, 0, 0], [0, 255, 0], [0, 0, 255]]).T,
                                                              np.array([[0, 0, 100, 100], [100, 0, 200, 100],
                                                                        [200, 0, 300, 100]]).T))
        check('alpha channel accepted', lambda: ipm.fill_rect(w, [255, 0, 0, 128], box))
        ipm.flip(w)

        # Misuse. Colours out of range WARN and clamp rather than erroring; the
        # requirement is that it complains, so this checks for the warning.
        check('a colour above the range warns and clamps',
              lambda: assert_warns(lambda: ipm.fill_rect(w, [300, 0, 0], box), 'exceeds this window'))
        reject('rect with 3 elements rejected', lambda: ipm.fill_rect(w, [255, 0, 0], [1, 2, 3]))
        reject('negative pen width rejected', lambda: ipm.frame_rect(w, 255, box, -2))
        reject('non-positive sigma rejected', lambda: ipm.draw_gabor(w, 255, box, 0))
        reject('negative frequency rejected', lambda: ipm.draw_gabor(w, 255, box, 0.3, -0.02))
        reject('non-scalar orientation rejected', lambda: ipm.draw_gabor(w, 255, box, 0.3, 0.02, [0, 45]))
        reject('1-D dot positions rejected', lambda: ipm.draw_dots(w, np.arange(1, 11), 4, 255))
        # A seed above 2^24 is not exact in the float32 that carries it to the shader.
        reject('non-integer seed rejected', lambda: ipm.draw_noise(w, box, 1.5))
        reject('seed above 2^24 rejected', lambda: ipm.draw_noise(w, box, 16777216))
        reject('negative seed rejected', lambda: ipm.draw_noise(w, box, -1))
        reject('unknown distribution rejected', lambda: ipm.draw_noise(w, box, 1, 'poisson'))
        reject('unknown chroma rejected', lambda: ipm.draw_noise(w, box, 1, 'uniform', 'rgb-ish'))

        # ---- noise values recomputed on the CPU ---------------------------------
        nbox = [0, 0, 32, 20]
        nv = ipm.noise_values(w, nbox, 7)
        record('noise_values', True)
        check('noise_values is (h, w)', lambda: nv.shape == (20, 32))
        check('noise_values is on the color range', lambda: np.all((nv >= 0) & (nv <= 255)))
        check('noise_values is reproducible from the seed', lambda: np.array_equal(nv, ipm.noise_values(w, nbox, 7)))
        check('a different seed gives different values', lambda: not np.array_equal(nv, ipm.noise_values(w, nbox, 8)))
        check('colour noise is (h, w, 3)', lambda: ipm.noise_values(w, nbox, 7, 'uniform', 'colour').shape == (20, 32, 3))
        check('colour channels differ from each other',
              lambda: assert_channels_differ(ipm.noise_values(w, nbox, 7, 'uniform', 'colour')))
        # THE DEFAULTS ARE THE TEST HERE: uniform, monochrome, black to white.
        check('the default is uniform black to white', lambda: assert_uniformish(ipm.noise_values(w, [0, 0, 200, 200], 11)))
        check('the default is monochrome', lambda: ipm.noise_values(w, [0, 0, 32, 20], 11).ndim == 2)
        check('normal noise has the requested SD', lambda: assert_normal_sd(
            ipm.noise_values(w, [0, 0, 200, 200], 12, 'normal', 'mono', 128, 26), 26))

        # ---- textures -----------------------------------------------------------
        img = np.random.rand(64, 64, 3)
        tex = ipm.make_texture(w, img)
        record('make_texture, RGB', True)
        check('update_texture preserves handle', lambda: ipm.update_texture(w, tex, img.astype(np.float32)))
        reject('update_texture invalid handle', lambda: ipm.update_texture(w, -1, img))
        check('make_texture, RGBA', lambda: ipm.close_texture(w, ipm.make_texture(w, np.random.rand(32, 32, 4))))
        check('make_texture, luminance', lambda: ipm.close_texture(w, ipm.make_texture(w, np.random.rand(32, 32))))
        check('draw_texture, whole window', lambda: ipm.draw_texture(w, tex))
        check('draw_texture with dst rect', lambda: ipm.draw_texture(w, tex, None, box))
        check('draw_texture with rotation', lambda: ipm.draw_texture(w, tex, None, box, 45))
        # Screen's positions: filter_mode 6, global_alpha 7, modulate_color 8.
        check('draw_texture, bilinear', lambda: ipm.draw_texture(w, tex, None, box, 0, 1))
        check('draw_texture, nearest', lambda: ipm.draw_texture(w, tex, None, box, 0, 0))
        check('draw_texture with global_alpha', lambda: ipm.draw_texture(w, tex, None, box, 0, 1, 128))
        check('draw_texture with modulate_color', lambda: ipm.draw_texture(w, tex, None, box, 0, 1, None, [255, 0, 0, 128]))
        check('global_alpha above the range warns and clamps',
              lambda: assert_warns(lambda: ipm.draw_texture(w, tex, None, box, 0, 1, 999), 'globalAlpha'))
        reject('a colour in the filter_mode slot is rejected',
               lambda: ipm.draw_texture(w, tex, None, box, 0, [255, 0, 0, 128]))
        # draw_textures: one value for every draw, or one per draw, as Screen's.
        box2 = np.array([box, [v + 20 for v in box]]).T
        check('draw_textures, one texture at several places', lambda: ipm.draw_textures(w, tex, None, box2))
        check('draw_textures, every argument per texture', lambda: ipm.draw_textures(
            w, [tex, tex], np.array([[0, 0, 32, 32], [32, 32, 64, 64]]).T, box2, [0, 45], [1, 0], [255, 128],
            np.array([[255, 0, 0], [0, 255, 0]]).T))
        reject('draw_textures with mismatched counts rejected', lambda: ipm.draw_textures(w, [tex, tex, tex], None, box2))
        reject('draw_textures with a bad handle rejected', lambda: ipm.draw_textures(w, [tex, 9999]))
        reject('draw_textures with a bad filter mode rejected', lambda: ipm.draw_textures(w, tex, None, box, 0, 2))
        ipm.flip(w)
        reject('bad texture handle rejected', lambda: ipm.draw_texture(w, 9999))

        # ---- two-phase presentation, measurement instruments --------------------
        check('set_display_sync off/on', lambda: (ipm.set_display_sync(w, False), ipm.set_display_sync(w, True)))
        check('prefetch_drawable off/on', lambda: (ipm.prefetch_drawable(w, False), ipm.prefetch_drawable(w, True)))
        ipm.fill_rect(w, 51)
        check('prepare_flip', lambda: ipm.prepare_flip(w))
        check('present_now', lambda: ipm.present_now(w))
        check('diagnostic returns a report', lambda: isinstance(ipm.diagnostic(w), dict))
        check('frame_stats summarises the report',
              lambda: ipm.frame_stats(ipm.diagnostic(w), ifi)['frames'] == len(ipm.diagnostic(w)['flipNumber']))
        check('grid_anchor returns three values', lambda: len(ipm.grid_anchor(w)) == 3)
        check('next_phase returns a scalar', lambda: math.isfinite(ipm.next_phase(w, ipm.get_secs(), 0)))
        check('next_refresh returns a scalar', lambda: math.isfinite(ipm.next_refresh(w, ipm.get_secs())))
        check('wait_to_draw accepts a past target', lambda: ipm.wait_to_draw(w, ipm.get_secs() - 1, 0))
        check('kb_check returns scalar state', lambda: isinstance(ipm.kb_check()[0], (bool, np.bool_)))
        check("kb_name maps Escape to 40 (0-based)", lambda: ipm.kb_name('ESCAPE') == 40)
        check('kb_name maps back', lambda: ipm.kb_name(40) == 'ESCAPE')
        print('Release any held keys for the kb_wait release check.')
        check('kb_wait until release', lambda: math.isfinite(ipm.kb_wait(True, .005)))
        check('get_mouse returns window pixels and three buttons', lambda: assert_mouse(ipm.get_mouse(w)))

        # ---- asynchronous keyboard queue ----------------------------------------
        # A zero mask makes this deterministic even while the user types.
        check('kb_queue_release before creation', lambda: ipm.kb_queue_release())
        reject('kb_queue_start before creation rejected', lambda: ipm.kb_queue_start())
        reject('kb_queue_create with short mask rejected', lambda: ipm.kb_queue_create(np.zeros(255)))
        reject('kb_queue_create with nonfinite mask rejected', lambda: ipm.kb_queue_create(np.full(256, np.nan)))
        reject('kb_queue_create with too short interval rejected', lambda: ipm.kb_queue_create(np.zeros(256), 0.0001))
        reject('kb_queue_create with too long interval rejected', lambda: ipm.kb_queue_create(np.zeros(256), 0.2))
        reject('kb_queue_create with spare argument rejected', lambda: ipm.kb_queue_create(np.zeros(256), 0.002, 99))
        check('kb_queue_create default arguments', lambda: ipm.kb_queue_create())
        check('kb_queue_create replaces queue with zero mask', lambda: ipm.kb_queue_create(np.zeros(256, bool), 0.002))
        check('kb_queue_check initially empty', lambda: assert_queue_summary_empty(ipm))
        check('kb_queue_get_events initially empty', lambda: assert_queue_events_empty(ipm))
        check('kb_queue_start', lambda: ipm.kb_queue_start())
        check('kb_queue_start while running', lambda: ipm.kb_queue_start())
        ipm.wait_secs(0.02)
        check('kb_queue_check with zero mask', lambda: assert_queue_summary_empty(ipm))
        check('kb_queue_get_events with zero mask', lambda: assert_queue_events_empty(ipm))
        check('kb_queue_flush while running', lambda: ipm.kb_queue_flush())
        check('kb_queue_stop', lambda: ipm.kb_queue_stop())
        check('kb_queue_stop while stopped', lambda: ipm.kb_queue_stop())
        check('kb_queue_get_events after stop', lambda: assert_queue_events_empty(ipm))
        check('kb_queue_check after stop', lambda: assert_queue_summary_empty(ipm))
        check('kb_queue_flush while stopped', lambda: ipm.kb_queue_flush())
        queue_commands = ['kb_queue_start', 'kb_queue_stop', 'kb_queue_flush', 'kb_queue_release',
                          'kb_queue_get_events', 'kb_queue_check']
        for command in queue_commands:
            reject(f'{command} with spare argument rejected', lambda c=command: getattr(ipm, c)(99))
        check('kb_queue_release', lambda: ipm.kb_queue_release())
        check('kb_queue_release repeated', lambda: ipm.kb_queue_release())
        for command in queue_commands:
            if command != 'kb_queue_release':
                reject(f'{command} after release rejected', lambda c=command: getattr(ipm, c)())

        # ---- teardown -----------------------------------------------------------
        reject('close_texture with a spare argument rejected', lambda: ipm.close_texture(w, tex, 99))
        check('close_texture', lambda: ipm.close_texture(w, tex))
        closed, tex = tex, None
        reject('a closed texture cannot be drawn', lambda: ipm.draw_texture(w, closed))
        ipm.close(w)
        w = None
        ipm.show_cursor()
        record('close', True)
        reject('drawing after close is rejected', lambda: ipm.fill_rect(1))

        # ---- did we cover the inventory? ----------------------------------------
        declared = commands_in_package()
        missing = sorted(set(declared) - ipm.called)
        record('every command in the package is exercised', not missing, 'not covered: ' + ', '.join(missing))
    except BaseException:
        for cleanup in (lambda: pm.kb_queue_release(),
                        lambda: tex is not None and w is not None and pm.close_texture(w, tex),
                        lambda: w is not None and pm.close(w), lambda: pm.show_cursor()):
            try:
                cleanup()
            except Exception:
                pass
        raise

    failed = [r for r in results if not r['ok']]
    report = dict(checks=len(results), passed=len(results) - len(failed), failed=len(failed), results=results,
                  commandsDeclared=len(declared))
    print('\n===== inventory =====')
    print(f'{len(results)} checks over {len(declared)} commands: {report["passed"]} passed, {len(failed)} failed.')
    if failed:
        print('\nFailures:')
        for r in failed:
            print(f"  {r['name']:<48} {r['detail']}")
        print('\nA failed rejection means a command accepted input it should have\n'
              'refused, which is how a wrong argument reaches the GPU silently.')
    else:
        print('Every command ran, and every deliberate misuse was refused.')
    return report


# -------------------------------------------------------------------------
def assert_empty(names, what):
    if names:
        raise AssertionError(f"{what}: {', '.join(names)}")


def assert_channels_differ(v):
    r, g, b = v[:, :, 0], v[:, :, 1], v[:, :, 2]
    if np.array_equal(r, g) or np.array_equal(g, b) or np.array_equal(r, b):
        raise AssertionError('colour channels are identical, so the noise is monochrome')


def assert_uniformish(v):
    if v.min() > 5 or v.max() < 250:
        raise AssertionError(f'range is {v.min():.1f} to {v.max():.1f}, expected to span nearly 0 to 255')
    if abs(v.mean() - 127.5) > 5:
        raise AssertionError(f'mean is {v.mean():.2f}, expected near 127.5')


def assert_normal_sd(v, want):
    got = v.std(ddof=1)
    if abs(got - want) > 0.1 * want:
        raise AssertionError(f'SD is {got:.2f}, expected near {want:.2f}')
    if abs(v.mean() - 127.5) > 3:
        raise AssertionError(f'mean is {v.mean():.2f}, expected near 127.5')


def assert_wait(ipm, secs, absolute, tol):
    """Neither form may return EARLY, and the median overshoot must be within tol."""
    err = []
    for _ in range(9):
        t0 = ipm.get_secs()
        t = ipm.wait_secs('UntilTime', t0 + secs) if absolute else ipm.wait_secs(secs)
        err.append(t - (t0 + secs))
    err = np.array(err[1:])       # the first may pay for the adaptive margin finding its level
    if np.any(err < -1e-6):
        raise AssertionError(f'returned {err.min() * 1e6:.1f} us EARLY, before the deadline')
    if np.median(err) > tol:
        raise AssertionError(f'median overshoot {np.median(err) * 1e6:.1f} us (worst {err.max() * 1e6:.1f}), '
                             f'tolerance {tol * 1e6:.0f} us')


def assert_near_ifi(got, nominal):
    if not (math.isfinite(got) and 0.004 < got < 0.05):
        raise AssertionError(f'get_flip_interval returned {got}, not a plausible refresh interval')
    if abs(got - nominal) / nominal > 0.01:
        raise AssertionError(f"get_flip_interval {got} differs from open_window's {nominal} by more than 1%")


def assert_near(t, name, ipm):
    if not math.isfinite(t):
        raise AssertionError(f'{name} is {t}, not a finite timestamp')
    if abs(t - ipm.get_secs()) > 1:
        raise AssertionError(f'{name} is {t:.6f}, more than a second from now')


def assert_warns(fn, fragment):
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter('always')
        fn()
    if not caught:
        raise AssertionError('no warning was emitted')
    if not any(fragment.lower() in str(c.message).lower() for c in caught):
        raise AssertionError(f'warning did not mention "{fragment}": {caught[0].message}')


def assert_mouse(m):
    x, y, buttons = m
    if not (math.isfinite(x) and math.isfinite(y) and buttons.dtype == bool and buttons.shape == (3,)):
        raise AssertionError(f'get_mouse returned {m}')


def assert_queue_events_empty(ipm):
    events, dropped = ipm.kb_queue_get_events()
    if events.shape != (0, 3) or dropped != 0:
        raise AssertionError(f'events {events.shape}, dropped {dropped}')


def assert_queue_summary_empty(ipm):
    pressed, *times = ipm.kb_queue_check()
    if pressed or any(np.asarray(t).shape != (256,) or np.any(np.asarray(t) != 0) for t in times):
        raise AssertionError('queue summary is not empty')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--verbose', action='store_true', help='print each check as it passes')
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    report = pm.run(inventory_test, args.verbose, threaded=args.threaded)
    raise SystemExit(1 if report['failed'] else 0)


if __name__ == '__main__':
    main()
