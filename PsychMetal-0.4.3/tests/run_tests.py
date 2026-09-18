#!/usr/bin/env python3
"""Portable local regression runner; offscreen Metal can explicitly skip."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
def run(args, skip=False):
    print('+ '+' '.join(map(str,args)),flush=True)
    result=subprocess.run(list(map(str,args)),cwd=root)
    if skip and result.returncode==77:
        print('Metal pixel validation SKIPPED; run on a Mac with an accessible GPU.',flush=True)
    elif result.returncode:
        raise SystemExit(result.returncode)
for test in ['test_wrapper','test_headless']:
    # Run outside the package directory so the explicit mock path can take precedence.
    expression="addpath('%s'); %s('%s');" % (str(root/'tests').replace("'","''"),test,str(root).replace("'","''"))
    result=subprocess.run(['octave','--no-gui','--quiet','--eval',expression],cwd=tempfile.gettempdir())
    if result.returncode: raise SystemExit(result.returncode)
for test in ['test_mouse_dispatch.py','test_native_dispatch.py','test_timing_target.py','test_secure_input.py','test_startup_ready.py']: run(['python3',root/'tests'/test])
with tempfile.TemporaryDirectory(prefix='psychmetal-tests-') as temp:
    binary=Path(temp)/'queue'
    run(['clang++','-std=c++17','-pthread','-fsanitize=address,undefined',root/'tests/test_keyboard_queue.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'metal'
    run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_metal.mm','-o',binary]);run([binary],skip=True)
print('All available regression checks passed. Review explicit GPU skips above.')
