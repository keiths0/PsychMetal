#!/usr/bin/env python3
"""Build both front ends against the scripted engine and run their tests.

  * Python: PsychMetalPython.cpp + PsychMetalShared.cpp + tests/mock_engine.cpp
    -> a temporary psychmetal package; runs tests/test_python_frontend.py and
    tests/test_python_demos.py (every demo and hardware-check port).
  * Octave (when mkoctfile is available): PsychMetalMex.cpp + the same
    -> PsychMetalCore.mex; runs PsychMetalInventoryTest, PsychMetalReadbackTest, the dot demo's sprite
    path, test_headless.m and test_mex_frontend.m through the real MEX front
    end and PsychMetal.m.

No Mac or GPU is needed. Needs clang++ (the engine's image packer uses the
__fp16 storage type), Python headers and numpy; Octave is optional.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import sysconfig
import tempfile

root = Path(__file__).resolve().parents[1]
clang = shutil.which('clang++')
if not clang:
    raise SystemExit('clang++ is required (the image packer uses __fp16).')


def run(args, **kw):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kw)


with tempfile.TemporaryDirectory(prefix='psychmetal-frontends-') as temp:
    temp = Path(temp)

    # --- Python ---------------------------------------------------------------
    pkg = temp / 'python' / 'psychmetal'
    pkg.mkdir(parents=True)
    shutil.copy2(root / 'python' / 'psychmetal' / '__init__.py', pkg / '__init__.py')
    for script in (root / 'python').glob('*.py'):       # the demos and hardware checks
        shutil.copy2(script, temp / 'python' / script.name)
    ext = pkg / ('_psychmetal' + sysconfig.get_config_var('EXT_SUFFIX'))
    link = ['-bundle', '-undefined', 'dynamic_lookup'] if sys.platform == 'darwin' else ['-shared']
    run([clang, '-std=c++17', '-O1', '-g', '-fPIC', '-pthread', '-Wall', '-Wextra', '-Wpedantic',
         '-iquote', root, '-I' + sysconfig.get_paths()['include'],
         root / 'PsychMetalPython.cpp', root / 'PsychMetalShared.cpp', root / 'tests' / 'mock_engine.cpp',
         *link, '-o', ext])
    env = dict(os.environ, PYTHONPATH=str(temp / 'python'))
    run([sys.executable, root / 'tests' / 'test_python_frontend.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_python_demos.py'], env=env, cwd=temp)

    # --- Octave ---------------------------------------------------------------
    if shutil.which('mkoctfile') and shutil.which('octave'):
        mexdir = temp / 'mex'
        mexdir.mkdir()
        env = dict(os.environ, CXX=clang,
                   CXXFLAGS=f'-std=c++17 -O1 -g -fPIC -pthread -Wall -Wextra -iquote {root}', LDFLAGS='-pthread')
        run(['mkoctfile', '--mex', root / 'PsychMetalMex.cpp', root / 'PsychMetalShared.cpp',
             root / 'tests' / 'mock_engine.cpp', '-o', mexdir / 'PsychMetalCore.mex'], env=env, cwd=mexdir)
        # A copy of PsychMetal.m alone, so a real PsychMetalCore built in the
        # package folder can never shadow the test build.
        mroot = temp / 'm'
        mroot.mkdir()
        for name in ('PsychMetal.m', 'PsychMetalInventoryTest.m', 'PsychMetalReadbackTest.m', 'PsychMetalDotDemo.m',
                     'PsychMetalFrameStats.m'):
            shutil.copy2(root / name, mroot / name)
        # The MATLAB inventory test in full, and the dot demo's sprite path (one
        # DrawTextures call per frame), each stopped by the scripted click.
        programs = ("r = PsychMetalInventoryTest(); assert(r.failed == 0, 'inventory failures'); "
                    "r = PsychMetalReadbackTest(); assert(r.failed == 0 && r.checks == 15, 'readback failures'); "
                    "setenv('PM_MOCK_MOUSE', '25,0,0'); PsychMetalDotDemo(1); "
                    "[~, d] = PsychMetalCore('Diagnostic'); assert(d.texturesDrawn == 400 * 24); "
                    "disp('PASS: PsychMetalInventoryTest, PsychMetalReadbackTest and PsychMetalDotDemo sprites under Octave.')")
        env = dict(os.environ, PM_MOCK_DISPLAY='640x400@60')
        run(['octave', '--no-gui', '--quiet', '--eval', f"addpath('{mroot}'); addpath('{mexdir}','-begin'); {programs}"],
            cwd=tempfile.gettempdir(), env=env)
        for test in ("test_headless('%s')" % mroot, "test_mex_frontend('%s','%s')" % (mroot, mexdir)):
            expr = f"addpath('{root / 'tests'}'); addpath('{mexdir}','-begin'); {test}"
            run(['octave', '--no-gui', '--quiet', '--eval', expr], cwd=tempfile.gettempdir())
    else:
        print('Octave not found: MEX front-end tests SKIPPED.')
print('Front-end checks passed.')
