#!/usr/bin/env python3
"""The real Python extension, without opening a window (Python's test_headless.m).
Needs a built python/psychmetal/_psychmetal*.so (make python); skips otherwise."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
if not list((root / 'python' / 'psychmetal').glob('_psychmetal*')):
    print('Python extension not built (make python): headless Python check SKIPPED.')
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


assert core.version() == pm.version() == '0.5.0'
reject(core.queue_frame, message='PsychMetal is not open.')
reject(core.prepare_flip, message='PsychMetal is not open.')
reject(core.confirm_startup, message='PsychMetal is not open.')
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
assert 0.01 <= t1 - t0 < 0.05, t1 - t0
modes = pm.resolutions()
assert modes and all(m['width'] > 0 and m['hz'] > 0 for m in modes)
n = core.noise_values(4, 3, 7, 0, 1, (0.5, 0.5, 0.5), 0.25)
assert n.shape == (3, 4, 3) and 0 <= n.min() and n.max() <= 1
print('PASS: real Python extension ABI, closed-state rejection, mask rejection, queue lifecycle, clock, modes, noise.')
