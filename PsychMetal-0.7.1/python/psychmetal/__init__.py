"""psychmetal — native Metal stimulus presentation on Apple silicon, from Python.

The same engine as PsychMetal for MATLAB and Octave, with the same commands.
Each PsychMetal.m command is a function here, named in snake_case, taking the
same arguments in the same order with the same defaults:

    PsychMetal('OpenWindow', 0, [0 0 0])        pm.open_window(0, [0, 0, 0])
    PsychMetal('FillRect', w, 255, rect)         pm.fill_rect(w, 255, rect)
    PsychMetal('DrawTexture', w, t, [], dst)     pm.draw_texture(w, t, None, dst)
    [vbl,~,~,missed] = PsychMetal('Flip', w)     vbl, _, _, missed, _ = pm.flip(w)

MATLAB's empty [] (use the default) is None here. Colours run 0..255 by default,
as in MATLAB; pm.color_range(w, 1) switches to 0..1.

Conventions that differ from MATLAB, deliberately:
  * Key indices are 0-based. kb_name('ESCAPE') is 40, key_code[40] is Escape,
    and the key column of kb_queue_get_events() holds the same indices.
  * Several rectangles, dot positions and per-item colours keep MATLAB's
    orientation: 4xN, 2xN and 3xN/4xN arrays, one column per item. A 1-D
    array or list is always one item.
  * Images are numpy arrays of shape (H, W) or (H, W, C), C in 1, 3 or 4,
    in any memory layout; they are read in place, never copied.
  * Diagnostic and Resolution(s) return dicts instead of structs.

Batching. A drawing call costs microseconds of argument handling however much
it draws, so draw many shapes with one 4xN call (fill_rect, fill_oval,
draw_dots, ...) and many textures with one draw_textures call, rather than one
call per item.

Threading. run(experiment) calls experiment on the main thread, as Octave's
command line does. run(experiment, threaded=True) calls it on a worker thread
while the main thread services AppKit, as MATLAB does; Ctrl-C then closes the
window at the next frame. Other Python threads keep running while flip() and
wait_secs() block, because the engine releases the GIL.

iPhone and iPad. The same engine and the same functions run inside an app
there. The main thread belongs to the app, so an experiment is started with
start(experiment), which returns at once, and ended early with stop(). Fingers
are the mouse: one is the pointer, a second down is button 1, and a third is
the Escape key; touch_events reports every finger as it is. Other keys are
those of an external keyboard.
What a phone does not have reports as much: one display mode, no cursor, no
link report, and a display that is always synchronized.
"""
import atexit as _atexit
import math as _math
import threading as _threading
import time as _time
import warnings as _warnings

import numpy as _np

from . import _psychmetal as _core

__version__ = '0.7.1'
PsychMetalError = _core.PsychMetalError

__all__ = [
    'PsychMetalError', 'run', 'version', 'make_stimulus', 'draw_stimulus',
    'open_window', 'close', 'make_texture', 'update_texture', 'draw_texture', 'draw_textures', 'close_texture',
    'blend_function', 'linearize', 'draw_text', 'text_bounds', 'link_info', 'fill_poly', 'frame_poly', 'clip',
    'open_offscreen_window', 'queue_flip', 'queue_results', 'queue_cancel', 'mouse_events', 'touch_events',
    'start', 'stop',
    'prefetch_drawable', 'color_range', 'get_secs', 'wait_secs', 'resolution', 'resolutions',
    'rect', 'window_size', 'get_flip_interval', 'background_color', 'get_mouse', 'set_mouse', 'hide_cursor',
    'show_cursor', 'kb_check', 'kb_queue_create', 'kb_queue_start', 'kb_queue_stop',
    'kb_queue_flush', 'kb_queue_release', 'kb_queue_get_events', 'kb_queue_check',
    'kb_queue_status', 'kb_wait', 'kb_name', 'get_image', 'noise_values', 'fill_rect', 'frame_rect',
    'fill_oval', 'frame_oval', 'draw_dots', 'draw_lines', 'draw_gabor', 'draw_noise', 'flip', 'flip_info',
    'prepare_flip', 'present_now', 'set_display_sync', 'grid_anchor', 'next_phase',
    'next_refresh', 'wait_to_draw', 'diagnostic', 'frame_stats',
]


def _array(buffer, code, shape):
    dtype = {'d': _np.float64, 'f': _np.float32, '?': _np.bool_, 'B': _np.uint8, 'H': _np.uint16}[code]
    return _np.frombuffer(buffer, dtype=dtype).reshape(shape)


_core.set_array_factory(_array)
_atexit.register(_core.shutdown)

if _core.version() != __version__:
    raise ImportError(f'psychmetal {__version__} found engine {_core.version()}; reinstall psychmetal, or rebuild it with make python.')

# The open window's state, as PsychMetal.m's persistent S.
_S = None
_abort = _threading.Event()
_secure_warned = False


# ----------------------------------------------------------------------------
# Argument checking
# ----------------------------------------------------------------------------

def _fail(message, id=''):
    e = PsychMetalError(message)
    e.id = id
    raise e


def _check(condition, message, *args):
    if not condition:
        _fail(message % args if args else message)


def _warn(id, message):
    _warnings.warn(f'{id}: {message}', stacklevel=3)


_SCALAR_TYPES = (bool, int, float, _np.bool_, _np.integer, _np.floating)


def _real(x):
    """One real number as a float (a Python or numpy scalar, or a one-element array), else None."""
    if isinstance(x, _SCALAR_TYPES):
        return float(x)
    a = _np.asarray(x)
    return float(a.reshape(-1)[0]) if a.size == 1 and a.dtype.kind in 'biuf' else None


def _number(x, message, ok=None):
    """A finite real number that passes ok, or PsychMetalError(message)."""
    v = _real(x)
    if v is None or not _math.isfinite(v) or (ok is not None and not ok(v)):
        _fail(message)
    return v


def _flag(x, name):
    v = _real(x)
    _check(v in (0.0, 1.0), '%s must be true or false.', name)
    return v == 1.0


def _open(w, what):
    """The window is open and w is its handle."""
    if _S is None:
        _fail('PsychMetal is not open.')
    if _real(w) != _S['buffer']:
        _fail(f'{what} requires the window handle from open_window.')


def _is_window(w):
    v = _real(w)
    return v is not None and (v == _S['buffer'] or v in _S['offscreen'])


def _window_rect(w):
    v = _real(w)
    return _S['physical_rect'] if v == _S['buffer'] else _S['offscreen'][v]


def _target(w, what):
    """The window or offscreen window a drawing function names: draws go into it
    from now on. Returns its rect."""
    if _S is None:
        _fail('PsychMetal is not open.')
    if not _is_window(w):
        _fail(f'{what} requires the window handle from open_window, or one from open_offscreen_window.')
    v = _real(w)
    want = 0 if v == _S['buffer'] else int(v)
    if want != _S['target']:
        _core.set_target(want)
        _S['target'] = want
    return _window_rect(w)


def _check_abort():
    if _abort.is_set():
        raise KeyboardInterrupt


def _is_empty(spec):
    return spec is None or (hasattr(spec, '__len__') and len(spec) == 0)


def _vector(a):
    """A 1-D array, or a 2-D array with one row or column."""
    return a.ndim <= 1 or (a.ndim == 2 and 1 in a.shape)


def _colors(spec, color_range):
    """Grey, RGB or RGBA in color_range: one colour (any vector), or one per
    item as a 3xN/4xN array -> (M, 4) in 0..1, M = 1 or N."""
    if _is_empty(spec):
        return _ONE_WHITE
    s = _np.asarray(spec)
    _check(s.dtype.kind in 'biuf', 'Colours must be real numbers.')
    if _vector(s):
        s = s.reshape(-1, 1)
    k = s.shape[0] if s.ndim == 2 else 0
    if k not in (1, 3, 4):
        _fail('Colour must be scalar grey, RGB or RGBA, optionally one per shape.', 'PsychMetal:Color')
    c = _np.empty((s.shape[1], 4))
    c[:, :3] = s[:3].T
    c[:, 3] = s[3] if k == 4 else color_range
    c /= color_range
    lo, hi = c.min(), c.max()
    _check(_math.isfinite(lo) and _math.isfinite(hi), 'Colour components must be finite.')
    if hi > 1.001:
        _warn('PsychMetal:ColorRange',
              f"A colour component of {hi * color_range:g} exceeds this window's ColorRange of "
              f'{color_range:g} and will be clamped. Set the range with color_range(w, r).')
    return _np.clip(c, 0, 1, out=c) if lo < 0 or hi > 1 else c


_ONE_WHITE = _np.ones((1, 4))
_ONE_WHITE.flags.writeable = False


def _rgba(spec, color_range):
    """Exactly one colour, as (4,) in 0..1."""
    c = _colors(spec, color_range)
    _check(len(c) == 1, 'Colour must be scalar grey, RGB or RGBA.')
    return c[0]


def _rects(spec, message, order=True):
    """[l t r b], or 4xN in MATLAB's orientation -> (N, 4); ordered so that
    left <= right and top <= bottom unless order is False."""
    r = _np.asarray(spec)
    _check(r.dtype.kind in 'biuf', message)
    r = r.reshape(1, -1) if _vector(r) else r.T
    _check(r.ndim == 2 and r.shape[1] == 4 and _math.isfinite(r.sum()), message)
    if not order:
        return r.astype(float)
    out = _np.empty(r.shape)
    _np.minimum(r[:, :2], r[:, 2:], out=out[:, :2])
    _np.maximum(r[:, :2], r[:, 2:], out=out[:, 2:])
    return out


def _values(spec, message, ok=None):
    """One value, or a vector of one per item -> 1-D float array (empty if absent)."""
    if _is_empty(spec):
        return _NONE
    if isinstance(spec, _SCALAR_TYPES):
        v = _np.array([float(spec)])
    else:
        v = _np.asarray(spec)
        _check(v.dtype.kind in 'biuf' and _vector(v), message)
        v = v.astype(float).ravel()
    _check(_math.isfinite(v.sum()) and (ok is None or ok(v)), message)
    return v


_NONE = _np.zeros(0)


def _each(a, n, what):
    """Broadcast one item, or check one per item, along the first axis."""
    if len(a) != n:
        _check(len(a) == 1, 'Supply one %s, or one per item (%d).', what, n)
        a = _np.broadcast_to(a, (n,) + a.shape[1:])
    return a


def _shapes(kind, param, rects, colors, extra=None):
    """Queue N shapes: rects, colors and extra (N, 4), colors possibly one row."""
    n = len(rects)
    if n:
        _core.add_shapes(_np.full(n, float(kind)), _np.full(n, param) if _np.ndim(param) == 0 else param, rects,
                         _each(colors, n, 'colour'), _np.zeros((n, 4)) if extra is None else _each(extra[None], n, 'x'))


# ----------------------------------------------------------------------------
# Window
# ----------------------------------------------------------------------------

class _Opened(tuple):
    """What open_window returns: the tuple (w, rect, ifi), and a context manager
    that closes that window and shows the cursor when its block ends."""
    __slots__ = ()

    def __enter__(self):
        return self

    def __exit__(self, kind, error, trace):
        try:
            if _S is not None and _S['buffer'] == self[0]:
                close(self[0])
        finally:
            show_cursor()
        return False


def open_window(screen=None, color=None, drawable_count=None, wait_for_confirm=None,
                display_sync=None, capture_display=None, refresh_hz=None, readback=None, bit_depth=None, presentation="auto"):
    """w, rect, ifi = open_window([screen, background, drawable_count, wait_for_confirm,
    display_sync, capture_display], refresh_hz=None, readback=None, bit_depth=None)

    Colours default to 0..255. Use a fixed display refresh mode for timing.
    presentation='displaylink' selects experimental CAMetalDisplayLink pacing
    (macOS 14 / iOS 17+). It supports Flip, but not QueueFlip, PrepareFlip or
    manual drawable prefetch. The default 'auto' selects display link on iOS 17+ and direct otherwise.
    readback=True makes frames readable by get_image. It is a diagnostic mode:
    every frame is copied, so take no timing from it. bit_depth=10 asks for ten
    bits per channel in the frame handed to the display; the default is 8.

    As the subject of a with statement the window is closed, and the cursor
    shown, when the block ends, whether it finishes, raises or is interrupted:

        with pm.open_window(0, [0, 0, 0]) as (w, rect, ifi):
            ...
    """
    global _S
    _check(_S is None, 'PsychMetal is already open. Close the existing window first.')
    scr = -1.0 if screen is None else _number(screen, 'Screen number must be a non-negative integer.',
                                              lambda v: v >= 0 and v == int(v))
    bg = _np.array([0, 0, 0, 1.0]) if color is None else _rgba(color, 255.0)
    count = 3.0 if drawable_count is None else _number(drawable_count, 'Maximum drawable count must be 2 or 3.',
                                                       lambda v: v in (2, 3))
    confirm = wait_for_confirm is not None and _flag(wait_for_confirm, 'waitForConfirm')
    vsync = display_sync is None or _flag(display_sync, 'displaySync')
    capture = capture_display is None or _flag(capture_display, 'captureDisplay')
    rb = readback is not None and _flag(readback, 'readback')
    bits = 8 if bit_depth is None else int(_number(bit_depth, 'bitDepth must be 8 or 10.', lambda v: v in (8, 10)))
    _check(isinstance(presentation, str) and presentation in ('auto', 'direct', 'displaylink'),
           "presentation must be 'auto', 'direct' or 'displaylink'.")
    if presentation == 'auto':
        presentation = 'displaylink' if _core.default_presentation() else 'direct'
    linked = presentation == 'displaylink'
    _check(not linked or vsync, 'Display-link presentation requires displaySync.')
    deep = bits != 8
    args = [scr, count, confirm, vsync, capture]
    # Trailing arguments are sent only as far as the last one that is not its
    # default. The core takes None for "no refresh override".
    if refresh_hz is not None or rb or deep or linked:
        args.append(None if refresh_hz is None else
                    _number(refresh_hz, 'refreshHz must be 20..1000.', lambda v: 20 <= v <= 1000))
    if rb or deep or linked:
        args.append(rb)
    if deep or linked:
        args.append(bits)
    if linked:
        args.append(True)
    try:
        _core.prepare_app()
        width, height, ifi, point_w, point_h, token = _core.open_session(*args)
        _core.set_background_color(*map(float, bg))
        began = _time.perf_counter()
        startup = _core.confirm_startup()
        startup_seconds = _time.perf_counter() - began
        link = _core.link_info()
    except BaseException:
        try:
            _core.close_session()
        except Exception:
            pass
        raise
    print(f'PsychMetal: {int(width)}x{int(height)} at {1 / ifi:.3f} Hz. {presentation} Metal presentation, no OpenGL.')
    print('PsychMetal: colours run 0-255, as Screen. pm.color_range(w, 1) for 0-1.')
    if deep:
        print('PsychMetal: 10 bits per channel requested. Whether the panel shows them is not checked.')
    if rb:
        print('PsychMetal: readback is on. Every frame is copied for get_image; do not take timing from this session.')
    if link[4] == 1:
        print(f'PsychMetal: this picture needs {link[3]:.1f} Gbit/s and the display link carries {link[2]:.1f}, '
              'so the link is\nPsychMetal: compressed (DSC). Fine detail that changes can alter static detail '
              'near it. See README.')
    display_rect = _np.array([0.0, 0.0, width, height])
    _S = dict(buffer=token, ifi=ifi, color_range=255.0, textures={},
              logical_rect=_np.array([0.0, 0.0, point_w, point_h]), physical_rect=display_rect.copy(),
              bg_color=bg, startup_history=startup, startup_seconds=startup_seconds,
              presentation=presentation, drawable_count=count, wait_for_confirm=confirm, readback=rb, bit_depth=bits, blend='alpha',
              linearize=None, offscreen={}, target=0, clip=None, last_vbl_confirmed=False,
              last_queue_ms=float('nan'), last_flip_ms=float('nan'), flip_count=0, slip_count=0,
              last_slip_flip=float('nan'), last_slip_refreshes=0.0)
    if count == 3 and not linked:
        _core.set_prefetch_drawable(True)
    return _Opened((token, display_rect, ifi))


def close(w):
    """close(w) releases the session. Queued work is cancelled. With an offscreen
    window's handle it closes that offscreen window only."""
    global _S
    if _S is not None and _real(w) in _S['offscreen']:
        close_texture(_S['buffer'], w)
        return
    _open(w, 'close')
    try:
        _core.close_session()
    finally:
        _S = None


def version():
    """The package version string, which the engine must match."""
    return __version__


# ----------------------------------------------------------------------------
# Textures
# ----------------------------------------------------------------------------

def _texture(tex):
    h = _real(tex)
    _check(h is not None and _math.isfinite(h), 'Invalid texture handle.')
    _check(h in _S['textures'], 'Unknown texture handle.')
    return int(h)


def _image_size(image):
    """(width, height, width, height), the divisor that normalises a source rect."""
    w, h = (image.shape[1] if image.ndim > 1 else 1), image.shape[0]
    return (w, h, w, h)


def make_texture(w, image):
    """tex = make_texture(w, image). Dense (H, W), (H, W, 3) or (H, W, 4): uint8
    uses 0..255; float32, float64 and bool use 0..1. Finite values clamp."""
    _open(w, 'make_texture')
    image = _np.asarray(image)
    handle = _core.make_texture(image)
    _S['textures'][handle] = _image_size(image)
    return handle


def update_texture(w, tex, image, rect=None):
    """update_texture(w, tex, image) replaces a texture's image, keeping its handle.

    update_texture(w, tex, image, rect) replaces only rect, [left, top, right,
    bottom] in whole texture pixels and the size of the image, in place: use it
    to change a small part of a large texture. The image must have the
    texture's kind (uint8 or bool, or float) and channel count."""
    _open(w, 'update_texture')
    h = _texture(tex)
    image = _np.asarray(image)
    if rect is None:
        _core.update_texture(h, image)
        _S['textures'][h] = _image_size(image)
        return
    message = 'The update_texture rect must be [left top right bottom] in whole texture pixels, the size of the image.'
    r = _np.asarray(rect)
    _check(r.dtype.kind in 'biuf' and r.size == 4 and image.ndim >= 1, message)
    r = r.astype(float).reshape(-1)
    iw, ih = _image_size(image)[:2]
    _check(_math.isfinite(r.sum()) and (r == _np.fix(r)).all() and r[2] - r[0] == iw and r[3] - r[1] == ih, message)
    _core.update_texture(h, image, r[0], r[1])


def draw_texture(w, tex, src_rect=None, dst_rect=None, angle=None, filter_mode=None,
                 global_alpha=None, modulate_color=None):
    """draw_texture(w, tex[, src_rect, dst_rect, angle, filter_mode, global_alpha, modulate_color])

    Rectangles are in pixels; angle in degrees; filter_mode 0 nearest or 1
    linear (default). global_alpha and modulate_color use the colour range.
    The default dst_rect is the source at native size, centred in the window.
    One texture of draw_textures, which takes the same arguments."""
    draw_textures(w, tex, src_rect, dst_rect, angle, filter_mode, global_alpha, modulate_color)


_FILTER_MESSAGE = ("filter_mode must be 0 (nearest) or 1 (bilinear), one or one per texture; Screen's "
                   'mipmap and oversampled modes 2-4 have no Metal equivalent.')


def draw_textures(w, texs, src_rects=None, dst_rects=None, angles=None, filter_modes=None,
                  global_alphas=None, modulate_colors=None):
    """draw_textures(w, texs[, src_rects, dst_rects, angles, filter_modes, global_alphas, modulate_colors])

    Many textures in one call, as Screen('DrawTextures'), drawn in order. Each
    argument is one value for every draw or one per draw: texs a handle or a
    sequence of handles, rectangles [l t r b] or 4xN, angles, filter modes and
    global alphas scalars or length N, colours one colour or 3xN/4xN. Defaults
    as draw_texture. Every draw is checked before any is queued."""
    target_rect = _target(w, 'draw_textures')
    h = _values(texs, 'Invalid texture handle.')
    _check(h.size, 'Invalid texture handle.')
    sizes = [_S['textures'].get(x) for x in h.tolist()]
    _check(None not in sizes, 'Unknown texture handle.')
    whwh = _np.array(sizes, dtype=float)                                # (k, 4) texture w, h, w, h
    src = None if _is_empty(src_rects) else _rects(
        src_rects, 'src_rect must be [left top right bottom] in texture pixels, or 4xN.', order=False)
    dst = None if _is_empty(dst_rects) else _rects(
        dst_rects, 'dst_rect must be [left top right bottom] in window pixels, or 4xN.')
    ang = _values(angles, 'The rotation angle must be finite: one, or one per texture.')
    fm = _values(filter_modes, _FILTER_MESSAGE, lambda v: set(v.tolist()) <= {0.0, 1.0})
    ga = _values(global_alphas, 'global_alpha must be finite: one, or one per texture.')
    tint = _colors(modulate_colors, _S['color_range'])
    n = max(len(h), 0 if src is None else len(src), 0 if dst is None else len(dst), len(ang), len(fm), len(ga),
            len(tint))
    h, whwh, tint = _each(h, n, 'texture'), _each(whwh, n, 'texture'), _each(tint, n, 'colour')
    if src is None:
        src = _np.zeros((n, 4))
        src[:, 2:] = whwh[:, 2:]
    src = _each(src, n, 'src_rect')
    if dst is None:                     # native size, centred in what is drawn into
        pr = target_rect
        centre = _np.array([(pr[0] + pr[2]) / 2, (pr[1] + pr[3]) / 2])
        half = _np.abs(src[:, 2:] - src[:, :2]) / 2
        dst = _np.hstack([centre - half, centre + half])
    dst = _each(dst, n, 'dst_rect')
    if ga.size:
        g = ga / _S['color_range']
        out = _np.flatnonzero((g > 1.001) | (g < -0.001))
        if out.size:
            _warn('PsychMetal:ColorRange', f"globalAlpha of {ga[out[0]]:g} is outside this window's ColorRange "
                                           f"of {_S['color_range']:g} and will be clamped.")
        tint = _np.array(tint)
        tint[:, 3] *= _each(_np.clip(g, 0, 1), n, 'global_alpha')
    # Rectangles and tints cross as (N, 4): the transpose of MATLAB's 4xN, same memory.
    _core.draw_textures(h, src / whwh, dst,
                        _each(ang if ang.size else _ZERO1, n, 'angle') * (_math.pi / 180), tint,
                        _each(fm if fm.size else _ONE1, n, 'filter_mode'))


_ZERO1, _ONE1, _ZERO2 = _np.zeros(1), _np.ones(1), _np.zeros(2)
_KEEP_CLIP = object()


def close_texture(w, tex):
    """close_texture(w, tex); handles expire permanently."""
    _open(w, 'close_texture')
    h = _texture(tex)
    _core.close_texture(h)
    del _S['textures'][h]
    _S['offscreen'].pop(h, None)
    if _S['target'] == h:
        _S['target'] = 0


def prefetch_drawable(w, on):
    """prefetch_drawable(w, flag) acquires the next drawable after submission; use three drawables."""
    _open(w, 'prefetch_drawable')
    flag = _flag(on, 'prefetch')
    if flag and _S['drawable_count'] < 3:
        _warn('PsychMetal:PrefetchStarvesPool',
              f"Prefetching with {int(_S['drawable_count'])} drawables starves the pool and halves the "
              'presentation rate. Open the window with 3 drawables instead.')
    _core.set_prefetch_drawable(flag)


_BLEND_MODES = ('alpha', 'add', 'copy')


def blend_function(w, mode=None):
    """old = blend_function(w[, 'alpha' | 'add' | 'copy']) sets how what is drawn from
    now on combines with what is already there. 'alpha' (the default) covers it
    in proportion to alpha; 'add' adds colour times alpha to it, so overlapping
    draws sum; 'copy' replaces it, alpha included, which is how to clear an
    offscreen window to transparent. The mode is kept across flip."""
    if _S is None or not _is_window(w):
        _open(w, 'blend_function')
    old = _S['blend']
    if mode is not None:
        m = mode.lower() if isinstance(mode, str) else None
        _check(m in _BLEND_MODES, "The blend mode must be 'alpha', 'add' or 'copy'.")
        _core.set_blend_mode(_BLEND_MODES.index(m))
        _S['blend'] = m
    return old


def clip(w, rect=_KEEP_CLIP):
    """old = clip(w, rect) confines everything drawn from now on to rect, [left, top,
    right, bottom] in whole pixels of what is drawn into. clip(w, None) ends it;
    clip(w) only reports it."""
    if _S is None or not _is_window(w):
        _open(w, 'clip')
    old = _S['clip']
    if rect is _KEEP_CLIP:
        return old
    if _is_empty(rect):
        _core.set_clip()
        _S['clip'] = None
        return old
    r = _np.asarray(rect)
    _check(r.dtype.kind in 'biuf' and r.size == 4, 'The clip rect must be [left top right bottom] in whole pixels.')
    r = r.astype(float).reshape(-1)
    _core.set_clip(tuple(r.tolist()))
    _S['clip'] = r
    return old


def open_offscreen_window(w, color=None, rect=None):
    """woff, rect = open_offscreen_window(w[, color, rect]) makes a window that is not shown.

    Draw into it with any drawing function by giving woff in place of w; what is
    drawn stays until it is drawn over. Then draw_texture(w, woff, ...) draws
    it, as a texture, as often as you like. color is what it holds at first
    (default the window's background); an alpha of 0 makes it transparent. rect
    gives its size (default the window's). It holds half-float values, so
    nothing drawn into it is rounded. Where it is partly transparent, drawing
    it gives what the draws made into it would have given if made there
    directly, soft edges included, and a global alpha applies to all of it.
    close(woff) or close_texture frees it."""
    _open(w, 'open_offscreen_window')
    rgba = _S['bg_color'] if color is None else _rgba(color, _S['color_range'])
    if rect is None:
        r = _S['physical_rect']
    else:
        r = _np.asarray(rect)
        _check(r.dtype.kind in 'biuf' and r.size == 4 and _np.isfinite(r.astype(float)).all(),
               'The offscreen window rect must be [left top right bottom] in whole pixels.')
        r = r.astype(float).reshape(-1)
    width, height = float(r[2] - r[0]), float(r[3] - r[1])
    handle = _core.open_offscreen(width, height, tuple(map(float, rgba)))
    own = _np.array([0.0, 0.0, width, height])
    _S['offscreen'][handle] = own
    _S['textures'][handle] = (width, height, width, height)
    return handle, own.copy()


_KEEP = object()


def linearize(w, spec=_KEEP):
    """old = linearize(w, gamma) makes every colour and texture value linear light
    for a display whose light is its input raised to gamma (one value, or
    [r, g, b]). Drawing and blending then happen in a 16-bit float frame and a
    last pass writes display values. linearize(w, table) takes an (N, 3) table
    instead: the display value 0..1 for each of N evenly spaced linear values.
    linearize(w, None) turns it off; linearize(w) only reports the setting.

    It costs one more full-screen pass per frame. The gamma or table must come
    from a photometer; psychmetal does not measure the display."""
    _open(w, 'linearize')
    old = _S['linearize']
    if spec is _KEEP:
        return old
    message = ("linearize takes the display's gamma (one value or [r g b], each 0.05 to 20), an (N, 3) table "
               'of display values 0..1 with N from 2 to 4096, or None to turn it off.')
    if _is_empty(spec):
        _core.set_gamma(1.0, 1.0, 1.0)
        _S['linearize'] = None
        return old
    a = _np.asarray(spec)
    _check(a.dtype.kind in 'biuf' and a.ndim <= 2 and _np.isfinite(a.astype(float)).all(), message)
    a = a.astype(float)
    if a.size in (1, 3) and _vector(a):
        g = _np.broadcast_to(a.reshape(-1), (3,))
        _check(((g >= 0.05) & (g <= 20)).all(), message)
        # The display raises its input to gamma, so the frame is raised to 1 / gamma.
        _core.set_gamma(*(1.0 / g).tolist())
    else:
        _check(a.ndim == 2 and a.shape[1] == 3 and 2 <= a.shape[0] <= 4096 and a.min() >= 0 and a.max() <= 1, message)
        a = _np.ascontiguousarray(a)
        _core.set_gamma_table(a)
    _S['linearize'] = a.copy()
    return old


def _text_args(text, size, font, wrap_width):
    _check(isinstance(text, str), 'The text must be a string.')
    pr = _S['physical_rect']
    px = float(_math.floor((pr[3] - pr[1]) / 30 + 0.5)) if size is None else _number(
        size, 'The text size must be a positive number of pixels.', lambda v: v > 0)
    _check(font is None or isinstance(font, str), 'The font must be a name.')
    wrap = _math.inf if wrap_width is None else _number(
        wrap_width, 'The wrap width must be a positive number of pixels.', lambda v: v > 0)
    return text, font or '', px, wrap


_layouts = {}       # (text, font, size, wrap) -> (lines, sizes, ascent); the last sixteen


def _layout(text, font, px, wrap):
    """Split text at newlines and, with a wrap width, between words; measure each
    line. sizes is (width, height) per line; an empty line has width 0."""
    key = (text, font, px, wrap)
    if key in _layouts:
        return _layouts[key]
    paragraphs = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    if _math.isfinite(wrap):
        # A space, without the two margins of each measured piece.
        space = _core.text_bounds('x x', font, px)[0] - 2 * _core.text_bounds('x', font, px)[0] + 2
        lines = []
        for paragraph in paragraphs:
            line, width = '', 0.0
            for word in paragraph.split(' '):
                if not word:
                    continue
                w = _core.text_bounds(word, font, px)[0] - 2
                if line and width + space + w > wrap - 2:
                    lines.append(line)
                    line, width = '', 0.0
                line, width = (word, w) if not line else (line + ' ' + word, width + space + w)
            lines.append(line)
    else:
        lines = paragraphs
    sizes, ascent = [], None
    for line in lines:
        if not line:
            sizes.append((0.0, 0.0))
            continue
        width, height, a = _core.text_bounds(line, font, px)
        sizes.append((width, height))
        ascent = a if ascent is None else ascent
    _check(ascent is not None, 'The text must not be empty.')
    if len(_layouts) >= 16:
        _layouts.pop(next(iter(_layouts)))
    _layouts[key] = (lines, sizes, ascent)
    return _layouts[key]


def _block(sizes, px):
    """(width, height) of the lines together, and the distance from one line's top to the next."""
    pitch = _math.floor(1.3 * px + 0.5)
    return max(w for w, _ in sizes), (len(sizes) - 1) * pitch + max(h for _, h in sizes), pitch


def text_bounds(w, text, size=None, font=None, wrap_width=None):
    """(rect, ascent) = text_bounds(w, text[, size, font, wrap_width]) measures text
    without drawing it: rect is [0, 0, width, height] in pixels."""
    if _S is None or not _is_window(w):
        _open(w, 'text_bounds')
    text, font, px, wrap = _text_args(text, size, font, wrap_width)
    _, sizes, ascent = _layout(text, font, px, wrap)
    width, height, _ = _block(sizes, px)
    return _np.array([0.0, 0.0, width, height]), ascent


def draw_text(w, text, x=None, y=None, color=None, size=None, font=None, wrap_width=None):
    """(rect, ascent) = draw_text(w, text[, x, y, color, size, font, wrap_width]) draws
    text with its top left at (x, y) in pixels; None for x centres each line and
    None for y centres the block. Newlines separate lines, and wrap_width
    (pixels) breaks lines between words. size is in pixels (default a thirtieth
    of the window height); font is a name (default Helvetica). rect is where it
    was drawn.

    Text is drawn in order with everything else. Each new line, font or size is
    rendered once and kept."""
    pr = _target(w, 'draw_text')
    text, font, px, wrap = _text_args(text, size, font, wrap_width)
    message = 'The text position must be finite, in window pixels; None centres it.'
    left, top = [None if v is None else _number(v, message) for v in (x, y)]
    lines, sizes, ascent = _layout(text, font, px, wrap)
    width, height, pitch = _block(sizes, px)
    if top is None:
        top = float(_math.floor((pr[1] + pr[3]) / 2 - height / 2 + 0.5))
    rgba = tuple(map(float, _rgba(color, _S['color_range'])))
    drawn = []
    for k, (line, (line_w, line_h)) in enumerate(zip(lines, sizes)):
        if not line:
            continue
        lx = float(_math.floor((pr[0] + pr[2]) / 2 - line_w / 2 + 0.5)) if left is None else left   # each line centred
        ly = top + k * pitch
        _core.draw_text(line, font, px, lx, ly, rgba)
        l, t = _math.floor(lx + 0.5), _math.floor(ly + 0.5)
        drawn.append((l, t, l + line_w, t + line_h))
    d = _np.array(drawn, dtype=float)
    return _np.array([d[:, 0].min(), d[:, 1].min(), d[:, 2].max(), d[:, 3].max()]), ascent


def _polygon(w, what, color, points, pen):
    _target(w, what)
    message = 'The points must be (N, 2), one [x, y] per row, with at least three.'
    p = _np.asarray(points)
    _check(p.dtype.kind in 'biuf' and p.ndim == 2 and _np.isfinite(p.astype(float)).all(), message)
    if p.shape[1] != 2 and p.shape[0] == 2:          # 2xN, as draw_dots takes
        p = p.T
    _check(p.shape[1] == 2 and p.shape[0] >= 3, message)
    _core.draw_polygon(_np.ascontiguousarray(p, dtype=float), tuple(map(float, _rgba(color, _S['color_range']))), pen)


def fill_poly(w, color, points):
    """fill_poly(w, color, points) fills a polygon: points is (N, 2), one [x, y] per
    row, closed automatically, concave or self-crossing as you like (even-odd
    rule). Antialiased. A polygon is drawn on the CPU and kept by its shape, so
    one that only moves by whole pixels costs nothing more; very large ones
    are slow."""
    _polygon(w, 'fill_poly', color, points, 0.0)


def frame_poly(w, color, points, pen_width=None):
    """frame_poly(w, color, points[, pen_width]) strokes a polygon's outline, pen_width
    pixels wide (default 1), centred on its edges. Antialiased."""
    pen = 1.0 if pen_width is None else _number(pen_width, 'Pen width must be positive.', lambda v: v > 0)
    _polygon(w, 'frame_poly', color, points, pen)


def link_info(w):
    """The DisplayPort link to the display, as a dict: lanes, laneGbps, payloadGbps
    (what it can carry), pixelGbps (what this window needs) and compressed, which
    is 1 when the picture cannot fit and the link must be using Display Stream
    Compression. Values are nan when the link cannot be identified. Under
    compression, changing fine detail alters static detail near it."""
    _open(w, 'link_info')
    return dict(zip(('lanes', 'laneGbps', 'payloadGbps', 'pixelGbps', 'compressed'), _core.link_info()))


# ----------------------------------------------------------------------------
# Window properties and time
# ----------------------------------------------------------------------------

def color_range(w, new_range=None):
    """old = color_range(w[, new_range])."""
    _open(w, 'color_range')
    old = _S['color_range']
    if new_range is not None:
        _S['color_range'] = _number(new_range, 'ColorRange must be a positive scalar.', lambda v: v > 0)
    return old


def get_secs():
    """Seconds on the engine clock, the clock of every timestamp."""
    return _core.now()


def wait_secs(secs, until_time=None):
    """wait_secs(seconds) or wait_secs('UntilTime', deadline) -> time on return.
    Adaptive 4..20 ms spin margin; for relaxed waits use time.sleep."""
    if isinstance(secs, str):
        _check(secs.lower() == 'untiltime', "The only string form is wait_secs('UntilTime', t).")
        deadline = _number(until_time, 'The deadline must be a finite scalar.')
    else:
        _check(until_time is None, 'wait_secs takes one duration.')
        deadline = _core.now() + _number(secs, 'The duration must be a finite scalar.')
    return _core.wait_until(deadline)


def _screen(screen):
    return -1.0 if screen is None else _number(screen, 'Screen number must be a non-negative integer.',
                                               lambda v: v >= 0 and v == int(v))


def _modes(screen):
    return [dict(width=r[0], height=r[1], pixelWidth=r[2], pixelHeight=r[3], hz=r[4])
            for r in _core.modes(_screen(screen))]


def resolution(screen=None, width=None, height=None):
    """old = resolution(screen[, width, height]) queries or sets point dimensions
    with no window open. Supply both width and height."""
    _check((width is None) == (height is None), 'Supply both width and height.')
    old = _modes(screen)[0]
    if width is not None:
        _core.set_mode(_screen(screen), float(width), float(height))
    return old


def resolutions(screen=None):
    """List of display modes: dicts with width, height (points), pixelWidth, pixelHeight, hz."""
    return _modes(screen)


def rect(w):
    """The rect [0 0 width height] in pixels of the window, or of an offscreen window."""
    if _S is None or not _is_window(w):
        _open(w, 'rect')
    return _window_rect(w).copy()


def window_size(w):
    """(width, height) in pixels of the window, or of an offscreen window."""
    if _S is None or not _is_window(w):
        _open(w, 'window_size')
    r = _window_rect(w)
    return r[2] - r[0], r[3] - r[1]


def get_flip_interval(w):
    """The period measured from confirmed frames once 30 are in, else the nominal period."""
    _open(w, 'get_flip_interval')
    anchor, period, samples = _core.grid_anchor()
    return period if samples >= 30 and _math.isfinite(period) and period > 0 else _S['ifi']


def background_color(w, color):
    """background_color(w, color) -> the RGBA it set, 0..1."""
    _open(w, 'background_color')
    bg = _rgba(color, _S['color_range'])
    _core.set_background_color(*map(float, bg))
    _S['bg_color'] = bg
    return bg


# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------

def mouse_events(w):
    """(events, dropped) = mouse_events(w): mouse-button presses and releases since the
    last call, one row each: [time, button, pressed, x, y], button 1 left, 2 right,
    3 centre, x and y in window pixels. The time is the one the event carries,
    not when it was read. The first call starts listening and returns nothing,
    so call it once before the trial."""
    _check_abort()
    _open(w, 'mouse_events')
    return _core.mouse_events()


def touch_events(w):
    """(events, dropped) = touch_events(w): what fingers on a touch screen or a
    trackpad have done since the last call, or since the window opened, one row
    each: [time, finger, phase, x, y]. phase is 0 for a finger going down, 1 for
    each movement the system sampled, 2 for its lifting and 3 for the system
    taking it over. finger numbers the fingers that are down, from 1. The time
    is the one the event carries. x and y are in window pixels: on a touch
    screen where the finger is; on a trackpad the finger's place on the trackpad
    as a place in the window, the trackpad's corners being the window's.

    On an iPhone or iPad fingers are also the mouse and one key, so that a
    program written for those runs unchanged: one finger is the pointer
    (get_mouse), a second finger down is button 1 (get_mouse, mouse_events), and
    a third is the Escape key (kb_check, the keyboard queue). On a Mac the first
    call starts listening and returns nothing, as mouse_events does, and the
    trackpad's contacts arrive only while the pointer is over the window and the
    program is the active application."""
    _check_abort()
    _open(w, 'touch_events')
    return _core.touch_events()


def get_mouse(w):
    """(x, y, buttons) in window pixels; buttons is bool[3]: left, right, centre."""
    _check_abort()
    _open(w, 'get_mouse')
    x, y, b = _core.mouse()
    return x, y, _np.array(b, dtype=bool)


def set_mouse(w, x, y):
    """Move the cursor to (x, y) in window pixels. A hidden cursor stays hidden."""
    _check_abort()
    _open(w, 'set_mouse')
    message = 'set_mouse x and y must be finite real numbers, in window pixels.'
    _core.set_mouse(_number(x, message), _number(y, message))


def hide_cursor():
    """Hide the mouse cursor. get_mouse keeps reporting its position."""
    _core.set_cursor_visible(False)


def show_cursor():
    """Show the mouse cursor again."""
    _core.set_cursor_visible(True)


def kb_check():
    """(key_is_down, secs, key_code): key_code is bool[256], index = HID usage - 1.
    There is no device number: macOS merges every keyboard into one state."""
    global _secure_warned
    _check_abort()
    down, secs, key_code, secure_pid = _core.keys()
    if secure_pid != 0 and not _secure_warned:
        _secure_warned = True
        owner = f' (pid {int(secure_pid)})' if secure_pid > 0 else ''
        _warn('PsychMetal:SecureInput',
              f'Secure event input is active{owner}; keyboard state may be suppressed. Exit the password '
              'field or application holding it. kb_queue_status provides an on-demand owner-PID lookup. '
              'Warned once per session.')
    return down, secs, key_code


def kb_queue_create(key_mask=None, poll_interval=None):
    """kb_queue_create([key_mask256, poll_seconds]). The mask is indexed like key_code."""
    mask = _np.ones(256) if key_mask is None else _np.asarray(key_mask)
    _check(mask.dtype.kind in 'biuf' and mask.size == 256 and _np.isfinite(mask.astype(float)).all(),
           'keyMask must have 256 finite real entries.')
    interval = 0.002 if poll_interval is None else _number(poll_interval, 'pollInterval must be .001 to .1 seconds.',
                                                           lambda v: 0.001 <= v <= 0.1)
    _core.kb_queue_create(mask.astype(float).ravel(), interval)


def kb_queue_start():
    """Start background key polling on the queue from kb_queue_create; starting again is harmless."""
    _core.kb_queue_start()


def kb_queue_stop():
    """Stop polling; events are preserved."""
    _core.kb_queue_stop()


def kb_queue_flush():
    """Clear events and summaries, discarding scans that overlap the flush."""
    _core.kb_queue_flush()


def kb_queue_release():
    """Stop and free the keyboard queue; releasing when there is none is harmless."""
    _core.kb_queue_release()


def kb_queue_get_events():
    """(events, dropped): events is an n x 3 array [detection time, key index, pressed].
    Times are polled detection times, not hardware event times."""
    events, dropped = _core.kb_queue_get_events()
    events = events.copy()
    events[:, 1] -= 1          # HID usage -> 0-based key index
    return events, dropped


def kb_queue_check():
    """(pressed, first_press, first_release, last_press, last_release), each array[256]."""
    pressed, times = _core.kb_queue_check()
    return pressed, times[0], times[1], times[2], times[3]


def kb_queue_status():
    """Polling intervals, overflow and secureInputPID."""
    return _core.kb_queue_status()


def kb_wait(until_release=False, poll_interval=None):
    """Wait for a key press, or with until_release=True for all keys up -> secs."""
    release = _flag(until_release, 'untilRelease')
    interval = 0.005 if poll_interval is None else _number(poll_interval, 'pollInterval must be a positive scalar.',
                                                           lambda v: v > 0)
    while True:
        down, secs, _ = kb_check()
        if down != release:
            return secs
        _time.sleep(interval)


def _key_table():
    """(HID usage, name) pairs, as Psychtoolbox's KbName on macOS."""
    rows = [(3 + k, chr(ord('a') + k - 1)) for k in range(1, 27)]
    rows += [(29 + k, d) for k, d in enumerate(['1!', '2@', '3#', '4$', '5%', '6^', '7&', '8*', '9(', '0)'], 1)]
    rows += [(40, 'Return'), (41, 'ESCAPE'), (42, 'DELETE'), (43, 'tab'), (44, 'space'),
             (45, '-_'), (46, '=+'), (47, '[{'), (48, ']}'), (49, '\\|'), (51, ';:'), (52, '\'"'),
             (53, '`~'), (54, ',<'), (55, '.>'), (56, '/?'), (57, 'CapsLock')]
    rows += [(57 + k, f'F{k}') for k in range(1, 13)]
    rows += [(70, 'PrintScreen'), (71, 'ScrollLock'), (72, 'Pause'), (73, 'Insert'),
             (74, 'Home'), (75, 'PageUp'), (76, 'Delete'), (77, 'End'), (78, 'PageDown'),
             (79, 'RightArrow'), (80, 'LeftArrow'), (81, 'DownArrow'), (82, 'UpArrow'),
             (83, 'NumLockClear'), (84, 'Divide'), (85, 'Multiply'), (86, 'Subtract'),
             (87, 'Add'), (88, 'ENTER')]
    rows += [(88 + k, f'Keypad{k}') for k in range(1, 10)]
    rows += [(98, 'Keypad0'), (99, 'KeypadDecimal'), (100, 'NonUSBackslash'),
             (101, 'Application'), (103, 'KeypadEqual')]
    rows += [(91 + k, f'F{k}') for k in range(13, 25)]
    rows += [(117, 'Help'), (133, 'KeypadComma'), (135, 'International1'),
             (137, 'International3'), (144, 'Lang1'), (145, 'Lang2'),
             (224, 'LeftControl'), (225, 'LeftShift'), (226, 'LeftAlt'), (227, 'LeftGUI'),
             (228, 'RightControl'), (229, 'RightShift'), (230, 'RightAlt'), (231, 'RightGUI')]
    return rows


_NAME_OF = {usage - 1: name for usage, name in _key_table()}          # 0-based index -> name
_INDEX_OF = {name: index for index, name in _NAME_OF.items()}
# Case-insensitive fallback; where two names differ only in case ('DELETE' and
# 'Delete') the exact spelling decides, and otherwise the lower index wins.
_INDEX_OF_LOWER = {name.lower(): index for index, name in reversed(_NAME_OF.items())}


def kb_name(key):
    """Name -> 0-based key index; index -> name; key_code bool[256] -> list of names."""
    if isinstance(key, str):
        index = _INDEX_OF.get(key, _INDEX_OF_LOWER.get(key.lower()))
        _check(index is not None, "Unknown key name '%s'.", key)
        return index
    if _np.ndim(key) == 0:
        _check(int(key) in _NAME_OF, 'No key has index %s.', key)
        return _NAME_OF[int(key)]
    return [_NAME_OF.get(int(i), f'usage{int(i) + 1}') for i in _np.flatnonzero(key)]


# ----------------------------------------------------------------------------
# Drawing
# ----------------------------------------------------------------------------

_RECT_MESSAGE = 'The rectangle must be [left top right bottom], or 4xN for several.'


def _rect_shapes(kind, what, w, color, rect_, pen_width):
    own = _target(w, what)
    rects = own[None] if rect_ is None else _rects(rect_, _RECT_MESSAGE)
    pen = 1.0 if pen_width is None else _number(pen_width, 'Pen width must be positive.', lambda v: v > 0)
    _shapes(kind, pen, rects, _colors(color, _S['color_range']))


def fill_rect(w, color=None, rect=None, pen_width=None):
    """fill_rect(w[, color, rect]); rect is [l t r b] or 4xN, colours one or 3xN/4xN."""
    _rect_shapes(0, 'fill_rect', w, color, rect, pen_width)


def frame_rect(w, color=None, rect=None, pen_width=None):
    """frame_rect(w[, color, rect, pen_width])."""
    _rect_shapes(1, 'frame_rect', w, color, rect, pen_width)


def fill_oval(w, color=None, rect=None, pen_width=None):
    """fill_oval(w[, color, rect])."""
    _rect_shapes(2, 'fill_oval', w, color, rect, pen_width)


def frame_oval(w, color=None, rect=None, pen_width=None):
    """frame_oval(w[, color, rect, pen_width])."""
    _rect_shapes(3, 'frame_oval', w, color, rect, pen_width)


def _points(xy, message):
    """2xN positions (a 1-D pair is one point) -> (N, 2)."""
    p = _np.asarray(xy)
    _check(p.dtype.kind in 'biuf', message)
    p = p.reshape(-1, 1) if p.ndim <= 1 else p
    _check(p.ndim == 2 and p.shape[0] == 2 and _np.isfinite(p).all(), message)
    return p.T.astype(float)


def _centre(center):
    if center is None:
        return _ZERO2
    c = _values(center, 'The centre offset must be [x y].')
    _check(c.size == 2, 'The centre offset must be [x y].')
    return c


def draw_dots(w, xy, size=None, color=None, center=None, dot_type=None):
    """draw_dots(w, xy 2xN[, size, color, center, dot_type]); dot_type 0 square, 1-4 round."""
    _target(w, 'draw_dots')
    p = _points(xy, 'Dot positions must be 2xN.') + _centre(center)
    n = len(p)
    half = _each(_values(10 if size is None else size, 'Dot size must be scalar or 1xN.', lambda v: (v > 0).all()),
                 n, 'dot size')[:, None] / 2
    kind = 4
    if dot_type is not None:
        kind = 0 if _number(dot_type, 'dot_type must be 0 (square) or 1 to 4 (round).',
                            lambda v: v in (0, 1, 2, 3, 4)) == 0 else 4
    _shapes(kind, 0.0, _np.hstack([p - half, p + half]), _colors(color, _S['color_range']))


def draw_lines(w, xy, width=None, color=None, center=None):
    """draw_lines(w, xy 2xN with N even[, width, color, center]): endpoint pairs."""
    _target(w, 'draw_lines')
    message = 'Line endpoints must be 2xN with N even: pairs of points.'
    _check(_np.ndim(xy) == 2, message)
    p = _points(xy, message)
    _check(len(p) % 2 == 0, message)
    n = len(p) // 2
    widths = _each(_values(1 if width is None else width, 'Line width must be scalar or 1xN.', lambda v: (v > 0).all()),
                   n, 'line width')
    _shapes(5, widths, (p + _centre(center)).reshape(n, 4), _colors(color, _S['color_range']))


def draw_gabor(w, color=None, rect=None, sigma=None, freq=None, angle=None, phase=None):
    """draw_gabor(w[, color, rect, sigma, freq, angle, phase]): sigma as a fraction of
    the rect, spatial frequency in cycles per pixel, orientation and phase in degrees."""
    own = _target(w, 'draw_gabor')
    rects = own[None] if rect is None else _rects(rect, _RECT_MESSAGE)
    s = 0.35 if sigma is None else _number(sigma, 'sigma must be positive.', lambda v: v > 0)
    f = 0.0 if freq is None else _number(freq, 'Spatial frequency must be zero or positive, in cycles per pixel.',
                                         lambda v: v >= 0)
    a = 0.0 if angle is None else _number(angle, 'Orientation must be a scalar in degrees.')
    ph = 0.0 if phase is None else _number(phase, 'Phase must be a scalar in degrees.')
    _shapes(6, s, rects, _colors(color, _S['color_range']), _np.array([f, _math.radians(a), _math.radians(ph), 0.0]))


def get_image(w, rect=None, out=None):
    """image = get_image(w[, rect]): the last flipped frame as a uint8 (H, W, 3) RGB array,
    or as uint16 running 0..1023 from a window opened with bit_depth=10.

    The pixels are copied from the frame's own drawable after rendering and
    before presentation. rect is [left, top, right, bottom] in whole pixels;
    omit it for the whole frame. Requires open_window(readback=True). It shows
    what the GPU rendered, not what the display emitted. A full frame is
    width * height * 3 bytes; pass a rect to keep many frames.

    Optional out is a writable C-contiguous numpy array with the exact output
    shape and dtype (uint8, or uint16 for a 10-bit window). It is filled and
    returned unchanged, avoiding a new allocation. Do not access it on another
    thread during the call. This still waits for the latest GPU frame; it is
    not an asynchronous capture queue."""
    _open(w, 'get_image')
    _check(_S['readback'], 'GetImage requires a window opened with readback.')
    if rect is None:
        return _core.get_image(None, out)
    r = _np.asarray(rect)
    _check(r.dtype.kind in 'biuf' and r.size == 4,
           'GetImage rect must be [left top right bottom] in whole pixels inside the window.')
    return _core.get_image(tuple(float(v) for v in r.reshape(-1)), out)


def _noise_args(what, rect_, seed, distribution, chroma, mean, spread):
    r = _rects(rect_, f'{what} needs a rect [left top right bottom].')
    _check(len(r) == 1 and (r == _np.fix(r)).all(), '%s needs a rect [left top right bottom].', what)
    _check((r[0, 2:] - r[0, :2] >= 1).all(), '%s needs a rect at least one pixel across.', what)
    s = int(_np.random.randint(0, 16777216)) if seed is None else _number(
        seed, 'Seed must be an integer from 0 to 16777215.', lambda v: v == int(v) and 0 <= v <= 16777215)
    normal = False
    if distribution is not None:
        d = str(distribution).lower()
        _check(d in ('uniform', 'normal'), "Distribution must be 'uniform' or 'normal'.")
        normal = d == 'normal'
    colour = False
    if chroma is not None:
        c = str(chroma).lower()
        _check(c in ('mono', 'colour', 'color'), "Chroma must be 'mono' or 'colour'.")
        colour = c != 'mono'
    cr = _S['color_range']
    m = _np.array([0.5, 0.5, 0.5, 1.0]) if mean is None else _rgba(mean, cr)
    spr = 0.5 if spread is None else _number(spread, 'Spread must be zero or positive.', lambda v: v >= 0) / cr
    return r, int(s), normal, colour, m, spr


def _noise(r, s, normal, colour, m, spr):
    size = r[0, 2:] - r[0, :2]
    return _core.noise_values(round(size[0]), round(size[1]), s, normal, colour, tuple(m[:3]), spr) * _S['color_range']


def noise_values(w, rect, seed=None, distribution=None, chroma=None, mean=None, spread=None):
    """The exact values draw_noise draws, as an (H, W) or (H, W, 3) array in the colour range."""
    _open(w, 'noise_values')
    return _noise(*_noise_args('noise_values', rect, seed, distribution, chroma, mean, spread))


def draw_noise(w, rect, seed=None, distribution=None, chroma=None, mean=None, spread=None, values=False):
    """seed = draw_noise(w, rect[, seed, distribution, chroma, mean, spread]).
    With values=True returns (seed, noise values) as MATLAB's second output does."""
    _target(w, 'draw_noise')
    args = _noise_args('draw_noise', rect, seed, distribution, chroma, mean, spread)
    r, s, normal, colour, m, spr = args
    _shapes(7, spr, r, m[None], _np.array([s, float(normal), float(colour), 0.0]))
    return (s, _noise(*args)) if values else s


# ----------------------------------------------------------------------------
# Presentation
# ----------------------------------------------------------------------------

def flip(w, when=None):
    """(vbl, stimulus_onset, flip_return, missed, slipped) = flip(w[, when]).

    Default timestamps are predictions; wait_for_confirm at open_window requests
    measured presentedTime at reduced throughput. missed is negative when the
    deadline was met, as in Screen. A GPU failure, no drawable or a confirmation
    timeout raises an error. A frame that was submitted but never shown does
    not: flip returns its projected time, and flip_info(w) reports it."""
    _check_abort()
    _open(w, 'flip')
    target = 0.0 if when is None else _number(when, "'when' must be zero or a positive GetSecs timestamp.",
                                              lambda v: v >= 0)
    t, confirmed, slip, period, queue_ms, call_ms, returned, token = _core.flip(target)
    S = _S
    S['last_queue_ms'], S['last_flip_ms'], S['last_vbl_confirmed'] = queue_ms, call_ms, confirmed
    missed = t - target - period if target > 0 else 0.0
    slipped = slip if _math.isfinite(slip) else 0.0
    S['last_slip_refreshes'] = slipped
    if slipped != 0:
        S['slip_count'] += 1
        S['last_slip_flip'] = S['flip_count']
    S['flip_count'] += 1
    return t, t, returned, missed, slipped


def queue_flip(w, when):
    """(token, pending, capacity) = queue_flip(w, when) renders what is drawn now and
    returns at once; the frame is shown at the refresh at or after when, by a
    thread of its own. Queue frames in order of time, as far ahead as capacity
    allows (as many as fit in a gigabyte): the program can then be late by that
    many frames without one being missed. With every store in use queue_flip
    waits. No frame is skipped: a late one is shown at the next refresh.
    Timing is not yet validated."""
    _check_abort()
    _open(w, 'queue_flip')
    token, pending, capacity = _core.queue_flip(
        _number(when, 'The presentation time must be a positive GetSecs timestamp.', lambda v: v > 0))
    return token, pending, capacity


def queue_results(w, wait=True):
    """frames = queue_results(w[, wait]) waits (unless wait is False) for the frames
    queued since the last call and returns one row per frame: [requested time,
    presented time, status, token]; status 0 shown, 1 dropped, 2 pending, 3 GPU
    error, 4 no drawable, 5 cancelled. The presented time is nan unless shown.
    Each frame is reported once, with its outcome. The wait ends two seconds
    after the last frame's time; a frame still pending then is reported as
    pending, and again by the next call, until ten seconds after its own time."""
    _open(w, 'queue_results')
    return _core.queue_results(_flag(wait, 'wait'))


def queue_cancel(w):
    """n = queue_cancel(w) abandons queued frames not yet handed to the display."""
    _open(w, 'queue_cancel')
    return _core.queue_cancel()


def flip_info(w):
    """What became of the last flip, and counts for the session: a dict with
    confirmed, dropped, slipped (refreshes), queueMs, flipMs, flips,
    droppedFrames and slipFlips. confirmed means the display has reported the
    frame shown, dropped that it has reported it never shown. The report comes
    about a refresh after flip returns unless the window waits for confirmation,
    and until then both are False; the next flip makes them about the next
    frame. So in a loop that flips every refresh they say nothing, and
    droppedFrames is what to read, when the trial is over: it counts every
    frame of the session reported never shown, queued frames included,
    whenever its report came."""
    _open(w, 'flip_info')
    S = _S
    confirmed, dropped, dropped_frames = _core.flip_status()
    return dict(confirmed=confirmed, dropped=dropped, slipped=S['last_slip_refreshes'],
                queueMs=S['last_queue_ms'], flipMs=S['last_flip_ms'], flips=S['flip_count'],
                droppedFrames=dropped_frames, slipFlips=S['slip_count'])


def prepare_flip(w):
    """token = prepare_flip(w) encodes a frame; present_now(w) presents it. Diagnostic instruments."""
    _open(w, 'prepare_flip')
    return _core.prepare_flip()


def present_now(w):
    """(when, call_ms) = present_now(w)."""
    _open(w, 'present_now')
    return _core.present_now()


def set_display_sync(w, flag):
    """set_display_sync(w, flag): present on the display's refresh (True, the default) or as soon as
    possible (False, for measurement only; tearing is expected)."""
    _open(w, 'set_display_sync')
    _core.set_display_sync(_flag(flag, 'displaySync'))


def grid_anchor(w):
    """(anchor, period, samples) of the measured refresh grid; anchor is NaN before the first confirmed frame."""
    _open(w, 'grid_anchor')
    return _core.grid_anchor()


def next_phase(w, t, phase):
    """The next time at or after t at the given fraction of a refresh past the grid."""
    _open(w, 'next_phase')
    return _core.next_phase(_number(t, 'The time must be a finite GetSecs timestamp.'),
                            _number(phase, 'The phase must be a finite number.'))


def next_refresh(w, t):
    """The next refresh at or after t."""
    _open(w, 'next_refresh')
    return _core.next_refresh(_number(t, 'The time must be a finite GetSecs timestamp.'))


def wait_to_draw(w, target, budget=None):
    """(woke_at, lead, deadline) = wait_to_draw(w, target[, budget=0.004]): sleep until
    drawing must begin for a frame to present at target."""
    _open(w, 'wait_to_draw')
    t = _number(target, 'The target presentation time must be a finite GetSecs timestamp.')
    b = 0.004 if budget is None else _number(budget, 'The drawing budget must be a nonnegative number of seconds.',
                                             lambda v: v >= 0)
    return _core.wait_to_draw(t, b)


# ----------------------------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------------------------

def diagnostic(w):
    """Drain pending work and return confirmed history and stage timings (a dict),
    with the same fields as PsychMetal('Diagnostic', w)."""
    _open(w, 'diagnostic')
    h, summary = _core.diagnostic()
    S = _S
    summary.update(presentation=S['presentation'], lastQueueMs=S['last_queue_ms'], lastFlipMs=S['last_flip_ms'], colorRange=S['color_range'],
                   logicalRect=S['logical_rect'], physicalRect=S['physical_rect'],
                   waitForConfirm=S['wait_for_confirm'], lastVblConfirmed=S['last_vbl_confirmed'],
                   backgroundColor=S['bg_color'], flips=S['flip_count'], slipFlips=S['slip_count'],
                   droppedFrames=int(summary['missingPresentedTimes']), bitDepth=S['bit_depth'], blendFunction=S['blend'],
                   lastSlipFlip=S['last_slip_flip'], lastSlipRefreshes=S['last_slip_refreshes'])
    ifi = S['ifi']
    status = h[:, 3]
    actual = h[:, 2].copy()
    actual[status != 0] = _np.nan
    projected = h[:, 1]
    lead = (projected - h[:, 4]) / ifi
    lead = lead[_np.isfinite(lead)]
    summary['projectionLeadRefreshes'] = float(_np.median(lead)) if lead.size else float('nan')
    # Fit the refresh period on the longest run of consecutive confirmed frames.
    fit = _np.zeros(len(actual), dtype=bool)
    candidate = _np.flatnonzero((status == 0) & _np.isfinite(actual))
    if candidate.size:
        gaps = _np.diff(actual[candidate])
        new_run = _np.concatenate([[True], (_np.diff(candidate) != 1) | (gaps < 0.5 * ifi) | (gaps > 1.5 * ifi)])
        run_number = _np.cumsum(new_run)
        longest = _np.argmax(_np.bincount(run_number)[1:]) + 1
        fit[candidate[run_number == longest]] = True
    tick, when = h[fit, 0], actual[fit]
    if tick.size >= 2 and tick.max() > tick.min():
        ct, cw = tick - tick.mean(), when - when.mean()
        measured = float(_np.sum(ct * cw) / _np.sum(ct ** 2))
        resid = cw - measured * ct
        summary.update(measuredRefreshIFI=measured, measuredRefreshHz=1 / measured, measuredRefreshSamples=int(tick.size),
                       refreshFitRmsUs=float(_np.sqrt(_np.mean(resid ** 2)) * 1e6),
                       refreshFitMaxAbsUs=float(_np.max(_np.abs(resid)) * 1e6))
    else:
        summary.update(measuredRefreshIFI=float('nan'), measuredRefreshHz=float('nan'),
                       measuredRefreshSamples=int(tick.size), refreshFitRmsUs=float('nan'),
                       refreshFitMaxAbsUs=float('nan'))
    frame_id = _np.round((projected - projected[0]) / ifi) if len(projected) else _np.zeros(0)
    gpu_ms = _np.full(len(h), _np.nan)
    valid = (h[:, 8] > 0) & (h[:, 9] >= h[:, 8])
    gpu_ms[valid] = (h[valid, 9] - h[valid, 8]) * 1000
    sh = S['startup_history']
    summary['startupAttempts'] = int(sh.shape[0])
    summary['startupSeconds'] = S['startup_seconds']
    return dict(
        flipNumber=h[:, 0], frameID=frame_id, projectedTimestamp=projected, actualTimestamp=actual,
        actualStatus=status, targetErrorMs=(actual - projected) * 1000, scheduledAt=h[:, 4],
        projectionLeadMs=(projected - h[:, 4]) * 1000, confirmationCallbackTime=h[:, 5],
        confirmationDelayMs=(h[:, 5] - actual) * 1000, commandStatus=h[:, 6], requestedTime=h[:, 7],
        scheduledAfterWhenMs=(projected - h[:, 7]) * 1000, presentRequestedTime=h[:, 10],
        presentCallMs=h[:, 11],
        # measuredLeadMs is stamped when Flip starts, before nextDrawable, so it
        # includes drawable-pool backpressure; pipelineLeadMs is stamped at commit.
        measuredLeadMs=(actual - h[:, 4]) * 1000, committedTime=h[:, 12],
        pipelineLeadMs=(actual - h[:, 12]) * 1000, drawableWaitMs=h[:, 13], encodeMs=h[:, 14],
        prefetchWaitMs=h[:, 15], presentErrorMs=(actual - h[:, 10]) * 1000, gpuPassMs=gpu_ms,
        gpuStartTime=h[:, 8], gpuEndTime=h[:, 9], summary=summary,
        startup=dict(token=sh[:, 0], status=sh[:, 1], presentedTime=sh[:, 2], callbackTime=sh[:, 3],
                     gpuDone=sh[:, 4], committedTime=sh[:, 5], seconds=S['startup_seconds']))


def frame_stats(d, ifi, discard=0):
    """Presentation statistics from a diagnostic() history, as PsychMetalFrameStats.

    frame_stats(d, ifi) uses every row; frame_stats(d, ifi, 120) discards the
    first 120. Intervals are taken only between ADJACENT confirmed rows, and the
    rate comes from the MEAN interval, not the median, which would hide dropped
    frames. Returns a dict: frames, confirmed, unconfirmed, achievedHz,
    medianIntervalMs, p99IntervalMs, minIntervalMs, maxIntervalMs, spreadMs,
    onePerRefresh, skipped, gaps, leadMedianMs, leadRefreshes, pipelineLeadMs,
    pipelineRefreshes, drawableWaitMs."""
    _check(isinstance(d, dict) and 'actualStatus' in d and 'actualTimestamp' in d,
           'The first argument must be a PsychMetal Diagnostic history.')
    ifi = _number(ifi, 'ifi must be a positive scalar.', lambda v: v > 0)
    start = min(int(discard or 0), len(d['actualStatus']))
    status = _np.asarray(d['actualStatus'], dtype=float)[start:]
    actual = _np.asarray(d['actualTimestamp'], dtype=float)[start:]
    ok = (status == 0) & _np.isfinite(actual)
    adj = _np.flatnonzero(ok[:-1] & ok[1:])
    iv = (actual[adj + 1] - actual[adj]) * 1000
    gaps = _np.round(iv / (ifi * 1000))
    nan = float('nan')

    def picked(key):
        if key not in d or not ok.any():
            return _NONE
        v = _np.asarray(d[key], dtype=float)[start:][ok]
        return v[_np.isfinite(v)]

    def med(v):
        return float(_np.median(v)) if v.size else nan

    p99 = float(_np.percentile(iv, 99)) if iv.size else nan
    lead, pipe, dwait = picked('measuredLeadMs'), picked('pipelineLeadMs'), picked('drawableWaitMs')
    return dict(frames=int(status.size), confirmed=int(ok.sum()), unconfirmed=int((~ok).sum()),
                achievedHz=1000 / float(_np.mean(iv)) if iv.size else nan,
                medianIntervalMs=med(iv), p99IntervalMs=p99,
                minIntervalMs=float(iv.min()) if iv.size else nan, maxIntervalMs=float(iv.max()) if iv.size else nan,
                spreadMs=p99 - med(iv), onePerRefresh=int(_np.sum(gaps == 1)), skipped=int(_np.sum(gaps > 1)),
                gaps=gaps, leadMedianMs=med(lead), leadRefreshes=med(lead) / (ifi * 1000),
                pipelineLeadMs=med(pipe), pipelineRefreshes=med(pipe) / (ifi * 1000), drawableWaitMs=med(dwait))


# ----------------------------------------------------------------------------
# Running
# ----------------------------------------------------------------------------

def run(fn, *args, threaded=False, **kwargs):
    """Run fn(*args, **kwargs) and return its result.

    threaded=False: fn runs on the main thread, as under Octave's command line.
    threaded=True: fn runs on a worker thread while the main thread services
    AppKit, as under MATLAB. Ctrl-C then makes the next flip, get_mouse or
    kb_check raise KeyboardInterrupt in fn, so its cleanup (close) runs."""
    if not threaded:
        _abort.clear()
        return fn(*args, **kwargs)
    _check(_core.on_main_thread(), 'run(..., threaded=True) must be called from the main thread.')
    result, error = [None], [None]

    def worker():
        try:
            result[0] = fn(*args, **kwargs)
        except BaseException as e:   # re-raised on the main thread below
            error[0] = e

    _abort.clear()
    thread = _threading.Thread(target=worker, name='psychmetal-caller')
    thread.start()
    while thread.is_alive():
        try:
            _core.service_main_run_loop(0.05)
        except KeyboardInterrupt:
            _abort.set()
    thread.join()
    _abort.clear()
    if error[0] is not None:
        raise error[0]
    return result[0]


_started = None     # the thread start() last made


def start(fn, *args, done=None, **kwargs):
    """thread = start(fn, *args, **kwargs) runs fn on a thread of its own and returns
    at once. It is for a program whose main thread must go on running a loop of
    its own: an app on an iPhone, where the main thread belongs to the app, or a
    Mac program with its own window toolkit. When fn ends, done(result, error) is
    called on that thread; error is what fn raised, or None. A window fn left
    open is closed first. stop() ends fn at its next frame.

    While fn runs, the main thread must stay free and must leave psychmetal to
    fn: do not wait for the thread there, and expect a psychmetal call made
    there to raise rather than wait. One experiment runs at a time."""
    global _started
    _check(_started is None or not _started.is_alive(),
           'An experiment is already running: wait for it to end.')

    def worker():
        result = error = None
        before = _S
        try:
            result = fn(*args, **kwargs)
        except BaseException as e:      # handed to done, which decides what it is worth
            error = e
        if _S is not None and _S is not before:
            try:
                close(_S['buffer'])
            except Exception as e:
                error = error or e
        if done is not None:
            done(result, error)

    _abort.clear()
    _started = _threading.Thread(target=worker, name='psychmetal-caller', daemon=True)
    _started.start()
    return _started


def stop():
    """Make the experiment's next flip, get_mouse, mouse_events, touch_events or
    kb_check raise KeyboardInterrupt, from any thread: what Ctrl-C does under
    run(..., threaded=True). The experiment's own cleanup then closes the window.
    The next start or run clears it."""
    _abort.set()


# Reusable CPU descriptions, not full-frame arrays; each draw sends 15 numbers.
_STIMULUS_FIELDS = {'mean': (1, 4), 'contrast': (4, 5), 'frequency': (5, 6),
    'orientation': (6, 7), 'phase': (7, 8), 'seed': (8, 9), 'grain': (9, 10),
    'colour': (10, 11), 'normal': (11, 12), 'opacity': (12, 13),
    'aperture': (13, 14), 'sigma': (14, 15)}


def _stimulus_parameters(base, options):
    p = _np.array(base, dtype=float, copy=True)
    _check(p.shape == (15,), 'Invalid stimulus description.')
    for name, value in options.items():
        _check(name in _STIMULUS_FIELDS, 'Unknown stimulus option: ' + name)
        if name == 'aperture':
            _check(isinstance(value, str) and value in ('rect', 'ellipse', 'gaussian'),
                   'aperture must be rect, ellipse or gaussian.')
            value = ('rect', 'ellipse', 'gaussian').index(value)
        a = _np.asarray(value)
        _check(a.dtype.kind in 'biuf' and _np.isrealobj(a), 'Stimulus options must be real numbers.')
        lo, hi = _STIMULUS_FIELDS[name]
        _check(a.size == 1 or (name == 'mean' and a.size == 3), 'Invalid stimulus option size: ' + name)
        p[lo:hi] = a.reshape(-1)
    _core.check_stimulus(p)
    return p


def make_stimulus(kind, **options):
    """Reusable GPU noise/grating recipe; no window or image allocation needed.

    kind: 'grating' or 'noise'. Options: mean (scalar/RGB, 0..1), contrast
    (0..1), frequency (cycles/pixel), orientation and phase (degrees), seed,
    grain (noise-cell pixels), colour, normal, opacity, aperture ('rect',
    'ellipse', 'gaussian'), sigma (fraction of aperture half-width/height).
    Grating direction is its frequency-vector direction, clockwise from +x.
    Recipe values use 0..1 independently of color_range. See GPU-STIMULI.md.
    """
    _check(isinstance(kind, str) and kind in ('grating', 'noise'), 'kind must be grating or noise.')
    p = _stimulus_parameters([int(kind == 'noise'), .5, .5, .5, 1, .02, 0, 0, 1, 1, 0, 0, 1, 0, .35], options)
    return tuple(p.tolist())  # immutable, independent of display/session


def draw_stimulus(w, stimulus, dst_rect=None, mask=None, **overrides):
    """Draw a reusable recipe, optionally overriding parameters for this draw.

    mask is a MakeTexture handle for one-channel coverage (0 transparent,
    1 opaque), multiplied by the procedural aperture. It scales to dst_rect;
    carrier frequency and noise grain remain in display pixels. Parameters
    and the current mask texture version are captured at draw time.
    """
    _check_abort()
    _check(isinstance(stimulus, tuple) and len(stimulus) == 15, 'Use make_stimulus to create a recipe.')
    p = _stimulus_parameters(stimulus, overrides)
    # Validate before changing targets; native code revalidates at its boundary.
    _check(_S is not None and _is_window(w), 'draw_stimulus requires a window.')
    rect = _np.asarray(_window_rect(w) if dst_rect is None else dst_rect, dtype=float)
    _check(rect.size == 4 and _np.isfinite(rect).all(), 'Destination must be four finite coordinates.')
    rect = _np.ascontiguousarray(rect.reshape(4))
    _check(rect[2] > rect[0] and rect[3] > rect[1], 'Destination must have positive size.')
    m = 0 if mask is None else _number(mask, 'Invalid mask handle.', lambda v: v >= 1 and v == int(v))
    _target(w, 'draw_stimulus')
    _core.draw_stimulus(p, rect, m)


def recent_frames(w, count=32):
    """Bounded, non-draining snapshot: rows [token, status, presented, committed].

    Status 0 is confirmed, 1 dropped, 2 pending, 3 GPU error, 4 no drawable.
    Pending rows may be updated on later calls. Only status 0 with a positive
    presented timestamp measures presentation; committed is not presentation.
    """
    _open(w, 'recent_frames')
    if isinstance(count, bool) or not isinstance(count, (int, _np.integer)) or not 1 <= count <= 256:
        raise ValueError('count must be an integer from 1 to 256.')
    return _core.recent_frames(int(count))
