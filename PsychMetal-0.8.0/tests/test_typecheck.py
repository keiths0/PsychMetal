#!/usr/bin/env python3
"""Type-check the Objective-C++ engine without building it, for the Mac, the
iPhone and the iPhone simulator.

On macOS the check uses the real SDKs (the iPhone's if Xcode has it). Elsewhere
it uses tests/macstubs, which declare only the Apple APIs the engine uses, with
the SDK's signatures; with -DPM_STUB_IOS they declare UIKit and leave out what
only a Mac has, so the iPhone's side cannot lean on the Mac's. A type check
catches wrong selectors, properties, argument types and missing declarations;
it cannot catch behavioural changes, which need the hardware tests.
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
base = [clang, '-x', 'objective-c++', '-std=c++17', '-fobjc-arc', '-fblocks', '-fexceptions',
        '-fsyntax-only', '-Wall', '-Wextra', '-Wpedantic']


def sdk(name):
    r = subprocess.run(['xcrun', '-sdk', name, '--show-sdk-path'], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


if sys.platform == 'darwin':
    targets = [('the Mac', 'the macOS SDK', ['-isysroot', sdk('macosx'), '-mmacosx-version-min=14.0'])]
    phone = sdk('iphoneos')
    if phone:
        targets.append(('the iPhone', 'the iOS SDK', ['-isysroot', phone, '-target', 'arm64-apple-ios15.0']))
        simulator = sdk('iphonesimulator')
        if simulator:
            targets.append(('the iPhone simulator', 'the iOS simulator SDK',
                            ['-isysroot', simulator, '-target', 'arm64-apple-ios15.0-simulator']))
    else:
        print('No iOS SDK in this Xcode: the iPhone type check is SKIPPED.')
else:
    stubs = ['-fobjc-runtime=macosx-14.0', '-isystem', str(root / 'tests' / 'macstubs')]
    targets = [('the Mac', 'tests/macstubs', stubs),
               ('the iPhone', 'tests/macstubs with -DPM_STUB_IOS', stubs + ['-DPM_STUB_IOS']),
               ('the iPhone simulator', 'tests/macstubs with -DPM_STUB_IOS -DPM_STUB_SIMULATOR',
                stubs + ['-DPM_STUB_IOS', '-DPM_STUB_SIMULATOR'])]
for device, what, flags in targets:
    r = subprocess.run(base + flags + [str(root / 'PsychMetalEngine.mm')], capture_output=True, text=True)
    if r.returncode or 'warning' in r.stderr:
        print(r.stderr)
        sys.exit(f'PsychMetalEngine.mm does not type-check cleanly for {device}.')
    print(f'PASS: PsychMetalEngine.mm type-checks for {device} against {what} with -Wall -Wextra -Wpedantic.')
