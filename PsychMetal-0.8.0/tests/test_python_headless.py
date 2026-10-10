#!/usr/bin/env python3
"""The real Python extension, without opening a window (Python's test_headless.m).
Needs a built python/psychmetal/_psychmetal*.so (make python); skips otherwise."""
from pathlib import Path
import sys
import sysconfig

root = Path(__file__).resolve().parents[1]
# Only an extension built for this Python on this machine can load.
if not (root / 'python' / 'psychmetal' / ('_psychmetal' + sysconfig.get_config_var('EXT_SUFFIX'))).exists():
    print(f'No Python extension for this Python ({sysconfig.get_config_var("EXT_SUFFIX")}; make python): '
          'headless Python check SKIPPED.')
    sys.exit(0)
sys.path.insert(0, str(root / 'python'))
import numpy as np
import psychmetal as pm

core = pm._core


def reject(fn, *args, message=None):
    try:
        fn(*args)
    except pm.PsychMetalError as e:
        assert message is None or str(e) == message, f'{str(e)!r} != {message!r}'
        return
    raise AssertionError(f'{fn.__name__} accepted a call it should reject')


assert core.version() == pm.version() == '0.8.0'
reject(core.draw_masked_texture,1,np.zeros(14),0,message='PsychMetal is not open.')
core.cancel_timeline()  # safe before opening
core.cancel_timeline(False)
reject(core.play_timeline, 2, np.empty((0,6)), message='PsychMetal is not open.')
reject(core.flip, message='PsychMetal is not open.')
reject(core.prepare_flip, message='PsychMetal is not open.')
reject(core.confirm_startup, message='PsychMetal is not open.')
reject(core.set_blend_mode, 1, message='PsychMetal is not open.')
reject(core.set_gamma, 0.5, 0.5, 0.5, message='PsychMetal is not open.')
reject(core.set_gamma_table, np.zeros((4, 3)), message='PsychMetal is not open.')
reject(core.text_bounds, 'a', '', 20, message='PsychMetal is not open.')
reject(core.draw_text, 'a', '', 20, 0, 0, (1, 1, 1, 1), message='PsychMetal is not open.')
reject(core.link_info, message='LinkInfo requires an open PsychMetal window.')
reject(core.set_clip, (0, 0, 10, 10), message='PsychMetal is not open.')
reject(core.open_offscreen, 10, 10, (0, 0, 0, 1), message='PsychMetal is not open.')
reject(core.set_target, 0, message='PsychMetal is not open.')
reject(core.draw_polygon, np.zeros((3, 2)), (1, 1, 1, 1), 0, message='PsychMetal is not open.')
reject(core.queue_flip, 1.0, message='PsychMetal is not open.')
reject(core.queue_results, True, message='PsychMetal is not open.')
reject(core.queue_cancel, message='PsychMetal is not open.')
reject(core.mouse_events, message='MouseEvents requires an open PsychMetal window.')
assert core.startup_history().shape == (0, 6)
reject(pm.kb_queue_create, np.ones(10), message='keyMask must have 256 finite real entries.')
reject(core.kb_queue_create, np.full(256, np.nan), 0.002, message='Key mask must be finite.')
pm.kb_queue_create(np.zeros(256, bool))
s = pm.kb_queue_status()
assert s['created'] and not s['running'] and s['dropped'] == 0
events, dropped = pm.kb_queue_get_events()
assert events.shape == (0, 3) and dropped == 0
pressed, a, b, c, d = pm.kb_queue_check()
assert not pressed and a.shape == (256,) and not (a.any() or b.any() or c.any() or d.any())
pm.kb_queue_flush(); pm.kb_queue_stop(); pm.kb_queue_release()
s = pm.kb_queue_status()
assert not s['created'] and not s['running']
reject(pm.kb_queue_start, message='Create a keyboard queue first.')
t0 = pm.get_secs(); t1 = pm.wait_secs(0.01)
# Shared runners may deschedule a correctly sleeping thread. Check the clock
# and the minimum wait; physical scheduling precision needs a hardware test.
assert 0.01 <= t1 - t0 < 1.0 and t1 <= pm.get_secs(), t1 - t0
try:
    modes = pm.resolutions()
except pm.PsychMetalError as e:
    if str(e) != 'No active displays.':
        raise
    print('Display-mode enumeration SKIPPED: no active display in this environment.')
else:
    assert modes and all(m['width'] > 0 and m['hz'] >= 0 for m in modes)
n = core.noise_values(4, 3, 7, 0, 1, (0.5, 0.5, 0.5), 0.25)
assert n.shape == (3, 4, 3) and 0 <= n.min() and n.max() <= 1
print('PASS: real Python extension ABI, closed-state rejection, mask rejection, queue lifecycle, clock, modes, noise.')
