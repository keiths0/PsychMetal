#!/usr/bin/env python3
"""Bisect the OpenWindow startup failure: direct presentation, four builds of
Open in one engine, chosen by temporary diagnostic switches.

    cd PsychMetal-0.9.0/python && PYTHONPATH=. python3 ../../probes/startup_probe_v3.py

PM_DIAG_OLD_SETTLE      Open waits a fixed second, as 0.8.1 did, with no
                        wait-for-visible and no Core Animation flush.
PM_DIAG_SOURCE_LIBRARY  the built-in shaders compiled from source at Open, as
                        0.8.1 did, instead of the precompiled library.
"""
import os
import subprocess
import sys

ONE = r'''
import time, warnings
import numpy as np
warnings.simplefilter('ignore')
from psychmetal import _psychmetal as core
core.prepare_app()
t = time.perf_counter()
core.open_session(-1.0, 3)
opened = time.perf_counter() - t
core.set_background_color(0.0, 0.0, 0.0, 1.0)
t = time.perf_counter()
try:
    core.confirm_startup(); result = 'CONFIRMED'
except Exception:
    result = 'FAILED'
h = np.asarray(core.startup_history())
print(f'open {opened:.2f} s, startup {result} after {time.perf_counter() - t:.2f} s, '
      f'{len(h)} frames, statuses {h[:, 1].astype(int).tolist() if len(h) else []}')
try:
    core.close_session()
except Exception:
    pass
'''
for settle in (False, True):
    for source in (False, True):
        env = dict(os.environ)
        env.pop('PM_DIAG_OLD_SETTLE', None); env.pop('PM_DIAG_SOURCE_LIBRARY', None)
        if settle: env['PM_DIAG_OLD_SETTLE'] = '1'
        if source: env['PM_DIAG_SOURCE_LIBRARY'] = '1'
        label = f"settle {'0.8.1' if settle else 'new  '}, shaders {'source  ' if source else 'metallib'}"
        out = subprocess.run([sys.executable, '-c', ONE], env=env, capture_output=True, text=True)
        lines = [l for l in (out.stdout + out.stderr).splitlines() if l.strip()]
        print(f'{label}: {lines[-1] if lines else "(no output)"}')
