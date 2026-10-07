# 0.7.0 development validation — 7 October 2026

- Built Octave 11.3.0, MATLAB R2026a and Python 3.14 ARM64 native modules.
- Native engine SDK type check passed with Wall/Wextra/Wpedantic. Octave linking retains the existing macOS-14 target versus macOS-26 library warning.
- Shared engine/front-end consistency check passed.
- New actual-native stimulus dispatch and validator passed address/undefined-behavior sanitizer checks for mask ownership, snapshots, range validation, blend/clip capture and rejection without appending draws.
- Real Python and Octave modules created and validated recipes without a display.
- Scripted-engine Python front end: 142 checks; Python demos: 93 checks. New Python and Octave stimulus demos also completed through the scripted engine.
- Scripted-engine Octave inventory: 221/221 over 68 commands; existing readback: 46/46. Additional frontend, demo and calibration checks passed.
- Real GPU stimulus pixel test compiled but skipped (no Metal device accessible).
- Standalone Metal shader compilation was attempted but the separate Xcode Metal Toolchain is absent. No shader execution/compilation pass on a GPU is claimed.
- The complete test runner is not green in this environment: its real Python display-enumeration test cannot run without active displays. Run the full suite and new GPU test on the target Mac.
- No physical display acceptance, MATLAB live-window testing or 0.7.0 performance/timing claims. This is an unpublished development candidate, not a validated experimental release.

The new shader is compiled by Metal when opening a window on the target Mac. Run tests/test_stimulus_metal.mm first (command in GPU-STIMULI.md), then the visual demos. The tests/mock_engine.cpp procedural entry is deliberately a contract stub, not a software substitute for GPU pixel validation.
