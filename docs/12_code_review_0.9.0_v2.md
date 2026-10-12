# PsychMetal 0.9.0 code review: what was done

October 12, 2026. Version 2. Version 1 is the review itself; this records what
was done about each item, and corrects one statement in it.

## Correction to version 1

Item 13 said drawable prefetch was used only by tests and probes. That was
wrong: prefetch was on by default for every window, and 0.8.x measured it as
worth about one refresh of mouse-to-photon latency in the mouse-rect demo
(docs/05_results.md, 9c). It was removed anyway, on Apple's guidance to take a
drawable as late as possible, so that latency must be measured again.

## Status of each item

| # | Item | Done |
|---|------|------|
| 1 | Deprecated activation | `[NSApp activate]`. |
| 2 | Probes in the package | Moved to `probes/` at the repository root (11 probes and `comparisons/`), with a README saying to run them with 0.8.1. `PsychMetalFrameStats.m` stays: it is documented and tested. |
| 3 | Guessed event times | Mouse events: `[NSEvent eventWithCGEvent:].timestamp`. Keys: see 4. |
| 4 | Two keyboard sources | `IOHIDManager` value callbacks with their own timestamps, on the input thread's run loop, when Input Monitoring is granted (`IOHIDCheckAccess`/`IOHIDRequestAccess`); otherwise polling. One source at a time; the reconciliation window is gone. Modifier bits use `NX_DEVICE…KEYMASK`. |
| 5 | Fixed wait at Open | Open waits for the window's occlusion state and position (2 s limit); Close for occlusion to clear (0.25 s limit). |
| 6 | Display capture | Removed, with its warning and the `captureDisplay` option. Not measured first. |
| 7 | Busy-spin waits | `THREAD_TIME_CONSTRAINT_POLICY` during waits; the spin margin adapts from 0.5 ms (was at least 4 ms) up to 20 ms after a late wake. Not measured first. |
| 8 | Shaders compiled at Open | Compiled at build time (`xcrun metal`, `metallib`, `tests/build_metallib.py`), embedded and loaded with `newLibraryWithData:`. Builds need the Metal toolchain. |
| 9 | Undocumented sources | `LinkInfo` kept, labelled best effort. `secureInputPID` dropped the session-dictionary lookup; `IsSecureEventInputEnabled` gives 0 or -1. |
| 10 | Polygons on the CPU | On the GPU: one quad per polygon, even-odd fill and distance antialiasing in the fragment shader, points in a ring of buffers. Checked pixel for pixel by `tests/test_polygon_metal.mm` (Mac only). Outlines now have round outer corners. |
| 11 | Float halving on the CPU | Left, as recommended. |
| 12 | Front-end duplication | Text layout, key names, stimulus and mask parameters, Tone, Click and WhiteNoise are in `PsychMetalShared.cpp`. Colour, rectangle and noise-argument expansion stay in each wrapper: they depend on each language's array layout. |
| 13 | Presentation knobs | `PrepareFlip`/`PresentNow`, `SetDisplaySync`, `PrefetchDrawable`, `waitForConfirm` removed. |
| 14 | Duplicated shader code | Shared Metal functions for the carrier, Gaussian and noise cell. |
| 15 | Diagnostic size | 25 fields. |
| 16 | CHANGELOG size | 0.1 to 0.6 moved to `docs/changelog-0.1-0.6.md`. |
| 17 | Interruption detection | A callback that starts more than 50 ms after the previous buffer ended warns and clears `timed`. Whether Siri stops the output (and is caught) is to be seen on the iPhone. |
| 18 | Separate audio units | Left, as recommended. |

## What has not been checked

Everything above passes the tests that run off a Mac: the scripted engine
through MATLAB/Octave and Python, the type check against stubs for the Mac,
iPhone and simulator, the C++ cores under sanitizers, and the phone app's
tests. None of it has run on Apple hardware yet. Version 1's advice to measure
before changing items 5 to 8 was overridden by the request to do everything
for 0.9.0, so these need measuring now, on a Mac and an iPhone:

- `make all` and `make test` (including the new polygon pixel test, and the
  metallib build for each SDK);
- the keyboard queue with and without Input Monitoring;
- Open's time and the window appearing on the right screen;
- frame timing and mouse-to-photon latency without prefetch and without capture;
- wake-up error and power with the time-constraint policy;
- the iPhone wheels and app, rebuilt.
