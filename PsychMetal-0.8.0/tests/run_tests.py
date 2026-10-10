#!/usr/bin/env python3
"""Portable local regression runner. Steps that need a built binary, Octave, a
Mac or a GPU run where those exist and say so where they do not."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
def run(args, skip=False):
    print('+ '+' '.join(map(str,args)),flush=True)
    result=subprocess.run(list(map(str,args)),cwd=root)
    if skip and result.returncode==77:
        print('Metal pixel validation SKIPPED; run on a Mac with an accessible GPU.',flush=True)
    elif result.returncode:
        raise SystemExit(result.returncode)
octave=shutil.which('octave')
# MATLAB/Octave wrapper against its .m mock, then headless against the real
# PsychMetalCore built in this folder (make octave).
# The committed binaries are for macOS: only a Mac can load them.
mac=sys.platform=='darwin'
tests=['test_wrapper']+(['test_headless'] if mac and (root/'PsychMetalCore.mex').exists() else [])
for test in tests if octave else []:
    # Run outside the package directory so the explicit mock path can take precedence.
    expression="addpath('%s'); %s('%s');" % (str(root/'tests').replace("'","''"),test,str(root).replace("'","''"))
    result=subprocess.run(['octave','--no-gui','--quiet','--eval',expression],cwd=tempfile.gettempdir())
    if result.returncode: raise SystemExit(result.returncode)
if not octave: print('Octave not found: MATLAB wrapper tests SKIPPED.')
elif 'test_headless' not in tests: print('No PsychMetalCore.mex for this machine (make octave on a Mac): real-MEX headless test SKIPPED.')
# Engine internals, boundary and parity, both front ends against the scripted
# engine, and the real Python extension headless.
for test in ['test_resource_lifetime.py','test_display_modes.py','test_store_packaging.py','test_readback_unpack.py','test_stimulus_native.py','test_masked_image_native.py','test_shader_native.py','test_masked_image_demo.py','test_play_timeline.py','test_engine_header.py','test_typecheck.py','test_mouse_dispatch.py','test_native_dispatch.py','test_noise_layout.py','test_mask_cache.py','test_fingers.py',
             'test_timing_target.py','test_flip_status.py','test_queue_results.py','test_render_failure.py','test_secure_input.py','test_startup_ready.py','test_frontends.py',
             'test_python_headless.py','test_phone_reports.py']:
    run([sys.executable,root/'tests'/test])
with tempfile.TemporaryDirectory(prefix='psychmetal-tests-') as temp:
    binary=Path(temp)/'live-timeline'
    run(['clang++','-std=c++17','-pthread','-fsanitize=address,undefined',root/'tests/test_live_timeline.cpp',root/'PsychMetalShared.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'timeline'
    run(['clang++','-std=c++17','-fsanitize=address,undefined',root/'tests/test_timeline.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'queue'
    run(['clang++','-std=c++17','-pthread','-fsanitize=address,undefined',root/'tests/test_keyboard_queue.cpp','-o',binary]);run([binary])
    if sys.platform=='darwin':
        binary=Path(temp)/'readback-buffer'
        run(['clang++','-std=c++17','-fobjc-arc','-iquote',root,'-framework','Foundation','-framework','Metal',root/'tests/test_readback_buffer.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal','-framework','CoreGraphics',root/'tests/test_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'display-link-handoff'
        run(['clang++','-std=c++17','-fobjc-arc','-mmacosx-version-min=14.0','-Wall','-Wextra','-Wpedantic','-framework','Foundation','-framework','QuartzCore','-framework','Metal',root/'tests/test_display_link.mm','-o',binary]);run([binary])
        binary=Path(temp)/'stimulus-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_stimulus_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'masked-image-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_masked_image_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'custom-shader-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_custom_shader_metal.mm','-o',binary]);run([binary],skip=True)
    else:
        print('Not macOS: Metal shader/pixel validation SKIPPED.')
print('All available regression checks passed. Review explicit skips above.')
