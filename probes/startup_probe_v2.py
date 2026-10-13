#!/usr/bin/env python3
"""Why does OpenWindow's startup confirmation fail? Opens a window each way
(direct presentation, then the display link) and prints what each startup
frame reported, without closing first, so nothing is lost.

    cd PsychMetal-0.9.0/python && PYTHONPATH=. python3 ../../probes/startup_probe_v2.py

Columns of the startup history: token, status (0 shown, 1 not shown, 2 pending,
3 GPU failure, 4 no drawable), presented time, callback time, GPU done, committed.
"""
import time
import warnings
warnings.simplefilter('always')
import numpy as np
import psychmetal as pm
from psychmetal import _psychmetal as core

np.set_printoptions(precision=4, suppress=True, linewidth=120)
for linked in (False, True):
    name = 'display link' if linked else 'direct'
    print(f'\n--- {name} ---')
    core.prepare_app()
    began = time.perf_counter()
    core.open_session(-1.0, 3, None, False, 8, linked)
    print(f'open_session: {time.perf_counter() - began:.3f} s')
    core.set_background_color(0.0, 0.0, 0.0, 1.0)
    began = time.perf_counter()
    try:
        core.confirm_startup()
        print(f'confirm_startup: confirmed in {time.perf_counter() - began:.3f} s')
    except Exception as e:
        print(f'confirm_startup: FAILED after {time.perf_counter() - began:.3f} s: {e}')
    print(np.asarray(core.startup_history()))
    try:
        core.close_session()
    except Exception as e:
        print(f'close: {e}')
