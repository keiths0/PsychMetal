#!/usr/bin/env python3
"""Type-check the Objective-C++ engine without building it.

On macOS the check uses the real SDK. Elsewhere it uses tests/macstubs, which
declare only the Apple APIs the engine uses, with the SDK's signatures. A type
check catches wrong selectors, properties, argument types and missing
declarations; it cannot catch behavioural changes, which need the hardware tests.
"""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
clang = shutil.which('clang++')
if not clang:
    print('clang++ not found: type check SKIPPED.')
    sys.exit(0)
flags = [clang, '-x', 'objective-c++', '-std=c++17', '-fobjc-arc', '-fblocks', '-fexceptions',
         '-fsyntax-only', '-Wall', '-Wextra', '-Wpedantic']
if sys.platform == 'darwin':
    sdk = subprocess.run(['xcrun', '-sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    flags += ['-isysroot', sdk, '-mmacosx-version-min=14.0']
    what = 'the macOS SDK'
else:
    flags += ['-fobjc-runtime=macosx-14.0', '-isystem', str(root / 'tests' / 'macstubs')]
    what = 'tests/macstubs'
r = subprocess.run(flags + [str(root / 'PsychMetalEngine.mm')], capture_output=True, text=True)
if r.returncode or 'warning' in r.stderr:
    print(r.stderr)
    sys.exit('PsychMetalEngine.mm does not type-check cleanly.')
print(f'PASS: PsychMetalEngine.mm type-checks against {what} with -Wall -Wextra -Wpedantic.')
