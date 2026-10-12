# PsychMetal 0.9.0 code review: what was done

October 12, 2026. Version 4. Version 1 is the review itself; this records what
was done about each item, and corrects one statement in it. Version 3 added the
first runs on the Mac, which undid items 1, 5 and 6; version 4 adds the latency
measurement that brought drawable prefetch back.

## Correction to version 1

Item 13 said drawable prefetch was used only by tests and probes. That was
wrong: prefetch was on by default for every window, and 0.8.x measured it as
worth about one refresh of mouse-to-photon latency in the mouse-rect demo
(docs/05_results.md, 9c). It was removed anyway, on a reading of Apple's
guidance to take a drawable as late as possible. Measured again, removal cost the
same refresh, so prefetch is back (item 13). That reading of the guidance was
also wrong: Apple's own frame loop, the display link's, hands over the drawable
before input is read, which is the order prefetch gives.

## Status of each item

| # | Item | Done |
|---|------|------|
| 1 | Deprecated activation | Tried `[NSApp activate]`; reverted. Since macOS 14 it is a request the active app must agree to, and a terminal that started the program does not (the app stayed inactive). `activateIgnoringOtherApps:` stays, with its warning suppressed on that line and the reason beside it. |
| 2 | Probes in the package | Moved to `probes/` at the repository root (11 probes and `comparisons/`), with a README saying to run them with 0.8.1. `PsychMetalFrameStats.m` stays: it is documented and tested. |
| 3 | Guessed event times | Mouse events: `[NSEvent eventWithCGEvent:].timestamp`. Keys: see 4. |
| 4 | Two keyboard sources | `IOHIDManager` value callbacks with their own timestamps, on the input thread's run loop, when Input Monitoring is granted (`IOHIDCheckAccess`/`IOHIDRequestAccess`); otherwise polling. One source at a time; the reconciliation window is gone. Modifier bits use `NX_DEVICE…KEYMASK`. |
| 5 | Fixed wait at Open | Tried waiting for AppKit to report the window visible; reverted to the fixed second. For a program started from Terminal the occlusion state never said visible, and with that wait the first directly presented frame never reported, so Open failed every time. Bisected on the Mac: the fixed wait confirmed with either shader library, the new one with neither. Why it stopped the first frame is not known. |
| 6 | Display capture | Kept, always on (it was the default); only the option to turn it off is gone. Removing it was not the cause of the failure above, but nothing measured says it can go. |
| 7 | Busy-spin waits | `THREAD_TIME_CONSTRAINT_POLICY` during waits; the spin margin adapts from 0.5 ms (was at least 4 ms) up to 20 ms after a late wake. Not measured first. |
| 8 | Shaders compiled at Open | Compiled at build time (`xcrun metal`, `metallib`, `tests/build_metallib.py`), embedded and loaded with `newLibraryWithData:`. Builds need the Metal toolchain. |
| 9 | Undocumented sources | `LinkInfo` kept, labelled best effort. `secureInputPID` dropped the session-dictionary lookup; `IsSecureEventInputEnabled` gives 0 or -1. |
| 10 | Polygons on the CPU | On the GPU: one quad per polygon, even-odd fill and distance antialiasing in the fragment shader, points in a ring of buffers. Checked pixel for pixel by `tests/test_polygon_metal.mm` (Mac only). Outlines now have round outer corners. |
| 11 | Float halving on the CPU | Left, as recommended. |
| 12 | Front-end duplication | Text layout, key names, stimulus and mask parameters, Tone, Click and WhiteNoise are in `PsychMetalShared.cpp`. Colour, rectangle and noise-argument expansion stay in each wrapper: they depend on each language's array layout. |
| 13 | Presentation knobs | `PrepareFlip`/`PresentNow`, `SetDisplaySync`, `waitForConfirm` and the `PrefetchDrawable` command removed. Prefetch itself was removed, measured, and restored, always on with direct presentation and three drawables, turned on by the engine after startup. Mouse to photons on the Mac: 2.96 refreshes without it, 2.82 with the display link, 1.96 with it (0.8.x: 1.96). |
| 14 | Duplicated shader code | Shared Metal functions for the carrier, Gaussian and noise cell. |
| 15 | Diagnostic size | 25 fields. |
| 16 | CHANGELOG size | 0.1 to 0.6 moved to `docs/changelog-0.1-0.6.md`. |
| 17 | Interruption detection | A callback that starts more than 50 ms after the previous buffer ended warns and clears `timed`. Whether Siri stops the output (and is caught) is to be seen on the iPhone. |
| 18 | Separate audio units | Left, as recommended. |

## What has been checked, and what has not

Off a Mac, everything passes: the scripted engine through MATLAB/Octave and
Python, the type check against stubs for the Mac, iPhone and simulator, the C++
cores under sanitizers, and the phone app's tests.

On the Mac (macOS 26, Metal Toolchain 27A266a): `make all` and `make test` pass,
after fixes the stubs had hidden (the Input Monitoring calls are declared in
`IOKit/hidsystem/IOHIDLib.h`; two Mac-only tests needed updating). Opening a
window failed until items 1, 5 and 6 were put back as above; 0.8.1 opened
normally on the same machine throughout, which is what showed the fault was in
this release.

Still to measure, on a Mac and an iPhone:

- the inventory and hardware tests, with a window;
- the keyboard queue with and without Input Monitoring;
- mouse-to-photon latency with prefetch restored (expected 1.96 refreshes);
- wake-up error and power with the time-constraint policy;
- the iPhone wheels and app, rebuilt.
