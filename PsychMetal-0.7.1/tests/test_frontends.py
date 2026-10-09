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
    for source in (root / 'python' / 'psychmetal').glob('*.py'):
        shutil.copy2(source, pkg / source.name)
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
    run([sys.executable, root / 'tests' / 'test_readback_out.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_python_demos.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_blob_array.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_presentation_backend.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_inspection.py'], env=env, cwd=temp)
    run([sys.executable, root / 'tests' / 'test_phone_demos.py'],
        env=dict(env, PYTHONPATH=os.pathsep.join([str(temp / 'python'), str(root / 'phone' / 'src')])), cwd=temp)

    run([sys.executable, root / 'tests' / 'test_app_reports.py'],
        env=dict(env, PYTHONPATH=os.pathsep.join([str(temp / 'python'), str(root / 'phone' / 'src')])), cwd=temp)
    run([sys.executable, root / 'tests' / 'test_frame_timing.py'],
        env=dict(env, PYTHONPATH=os.pathsep.join([str(temp / 'python'), str(root / 'phone' / 'src')])), cwd=temp)

    run([sys.executable, '-c', "import stimulus_demo; stimulus_demo.stimulus_demo(.1)"], env=dict(env, PM_MOCK_DISPLAY='640x400@60', PM_MOCK_MOUSE='3,320,200'), cwd=temp)

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
                     'PsychMetalBlobArrayDemo.m', 'PsychMetalFrameStats.m', 'PsychMetalDisplayTest.m', 'PsychMetalGammaCalibration.m', 'PsychMetalStimulusDemo.m'):
            shutil.copy2(root / name, mroot / name)
        # The MATLAB inventory test in full, and the dot demo's sprite path (one
        # DrawTextures call per frame), each stopped by the scripted click.
        programs = ("setenv('PM_MOCK_MOUSE','-1,0,0'); r=PsychMetalBlobArrayDemo(.1); assert(r.frames==6 && numel(r.frequencies)==7 && abs(r.frequencies(end)-.9375)<1e-10); "
                    "setenv('PM_MOCK_MOUSE','3,320,200'); PsychMetalStimulusDemo(.1); setenv('PM_MOCK_MOUSE','-1,0,0'); " "r = PsychMetalInventoryTest(); assert(r.failed == 0, 'inventory failures'); "
                    "r = PsychMetalReadbackTest(); assert(r.failed == 0 && r.checks == 46, 'readback failures'); "
                    "setenv('PM_MOCK_MOUSE', '25,0,0'); PsychMetalDotDemo(1); "
                    "[~, d] = PsychMetalCore('Diagnostic'); assert(d.texturesDrawn == 400 * 24); "
                    "setenv('PM_MOCK_MOUSE', '0,0,0'); setenv('PM_MOCK_LINK', '4,5.4'); said = evalc('r = PsychMetalDisplayTest();'); "
                    "setenv('PM_MOCK_LINK', ''); [h, d] = PsychMetalCore('Diagnostic'); "
                    "assert(size(h, 1) == 124 && isempty(r.colourTwinkleSeen) && isempty(r.gamma) && r.link.lanes == 4 && "
                    "~isempty(strfind(said, 'Gamma: not estimated.')) && numel(strfind(said, 'not answered')) == 3, 'display test'); "
                    "setenv('PM_MOCK_MOUSE', '-1,0,0'); "
                    "setenv('PM_MOCK_KEYS', '19:38-40,17:45-90,28:120-122,17:170-172,81:210-231,81:235-236,44:240-242'); "
                    "evalc('r = PsychMetalDisplayTest();'); setenv('PM_MOCK_KEYS', ''); "
                    "assert(isequal(r.colourTwinkleSeen, false) && isequal(r.greyTwinkleSeen, true) && isequal(r.dimmingSeen, false) && r.matchingGrey == 184, 'display test keys'); "
                    # The gamma calibration: an exact observer on a display of gamma 2.4, then by eye with
                    # scripted keys (Down held in the first match, Space every 40 frames, Y for the check).
                    "f = @(v) v .^ 2.4; g = (0:255) / 255; "
                    "obs = @(low, high, mask, pattern, start, label) find(abs(f(g) - (f(low / 255) + f(high / 255)) / 2) == "
                    "min(abs(f(g) - (f(low / 255) + f(high / 255)) / 2)), 1) - 1; "
                    "said = evalc('r = PsychMetalGammaCalibration(struct(''observer'', obs, ''seed'', 1));'); c = r.curves.grey; "
                    "assert(abs(c.gamma - 2.4) < 0.02 && r.complete && numel(r.matches) == 4 && isequal({r.matches.pattern}, {'rows4', 'cols4', 'rows4', 'rows4'}) && "
                    "isequal(size(r.table), [256 3]) && max(abs(f(r.table(:, 1)) - g')) < 0.02 && "
                    "~isempty(strfind(said, 'Rows and columns agree')) && isempty(strfind(said, 'Repeated matches')), 'gamma calibration, short form'); "
                    "said = evalc('r = PsychMetalGammaCalibration(struct(''observer'', obs, ''seed'', 1, ''full'', true));'); c = r.curves.grey; "
                    "assert(abs(c.gamma - 2.4) < 0.01 && c.rmsPower < 0.5 && c.rmsPower < c.rmsSRGB && r.complete && "
                    "numel(r.matches) == 30 && isequal(size(r.table), [256 3]) && all(diff(r.table(:, 1)) > 0) && "
                    "max(abs(f(r.table(:, 1)) - g')) < 0.01 && isempty(r.verified) && strcmp(r.pattern, 'rows8') && "
                    "~isempty(strfind(said, 'The finer patterns agree with them')), 'gamma calibration, long form'); "
                    "keys = '81:32-38,81:41-43'; for k = 0:3, keys = [keys sprintf(',44:%d-%d', 45 + 40 * k, 47 + 40 * k)]; end; "
                    "setenv('PM_MOCK_KEYS', [keys ',28:205-207']); "
                    "said = evalc('r = PsychMetalGammaCalibration(struct(''seed'', 5));'); setenv('PM_MOCK_KEYS', ''); "
                    "assert(numel(r.matches) == 4 && r.matches(1).matched == r.matches(1).start - 2 && "
                    "all([r.matches(2:end).matched] == [r.matches(2:end).start]) && isequal(r.verified, true) && "
                    "isequal(size(r.table), [256 3]), 'gamma calibration, by eye'); "
                    "setenv('PM_MOCK_MOUSE', '0,0,0'); said = evalc('r = PsychMetalGammaCalibration();'); setenv('PM_MOCK_MOUSE', '-1,0,0'); "
                    "assert(isempty(r.matches) && isempty(r.table) && ~isempty(strfind(said, 'Curve: not measured.')), 'gamma calibration, skipped'); "
                    "disp('PASS: PsychMetalInventoryTest, PsychMetalReadbackTest, PsychMetalDisplayTest, "
                    "PsychMetalGammaCalibration and PsychMetalDotDemo sprites under Octave.')")
        env = dict(os.environ, PM_MOCK_DISPLAY='640x400@60')
        run(['octave', '--no-gui', '--quiet', '--eval', f"addpath('{mroot}'); addpath('{mexdir}','-begin'); {programs}"],
            cwd=tempfile.gettempdir(), env=env)
        for test in ("test_headless('%s')" % mroot, "test_mex_frontend('%s','%s')" % (mroot, mexdir)):
            expr = f"addpath('{root / 'tests'}'); addpath('{mexdir}','-begin'); {test}"
            run(['octave', '--no-gui', '--quiet', '--eval', expr], cwd=tempfile.gettempdir())
    else:
        print('Octave not found: MEX front-end tests SKIPPED.')
print('Front-end checks passed.')
