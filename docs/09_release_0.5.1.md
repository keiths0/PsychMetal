# PsychMetal 0.5.1 — 2026-10-04

Native Metal stimulus presentation for Apple silicon, for MATLAB, Octave and Python. This release adds frame readback, speeds up texture upload, and removes two unused engine commands. The presentation and timing path is otherwise that of 0.5.0.

## Changes

- **Frame readback.** A window opened with the `readback` option copies every frame's own drawable, in the same GPU command buffer, after rendering and before presentation. `GetImage` (`get_image`) returns the frame most recently submitted by `Flip` as uint8 height × width × 3 RGB, or a `[left top right bottom]` rect of it. It is not a second rendering, so it cannot disagree with what was presented. Off by default; off, nothing is copied and the layer is framebuffer-only, as before. Take no timing from a readback session.
- **New tests.** `PsychMetalReadbackTest` and `python/readback_test.py` check the renderer pixel for pixel: an opaque rectangle and its edges, uint8 textures bit for bit, float textures, a masked texture over another, global alpha against α·top + (1−α)·bottom, and a texture updated on every frame.
- **Faster texture upload.** uint8 and logical images are packed through a lookup table instead of one double-precision conversion per element. The result is bit for bit the same. On an x86 test machine a uint8 image packs 5 to 13 times faster; it has not been timed on Apple silicon.
- **Removed.** The engine commands `SettleWindow` and `TimingPolicy`, which no host called, and with them the code for timing policies 1 and 2. `Diagnostic` no longer has the `timingPolicy` summary field or the pacing-wait history column (`pacingWaitMs`). Scripts that use `PsychMetal` or `psychmetal` are unaffected unless they read `pacingWaitMs`.
- **Engine internals** tidied with no change in behaviour intended; see the changelog.

## Compatibility and validation

Binaries are included for Octave 11.3.0 (Homebrew), MATLAB R2026a and Python 3.14 on Apple silicon. Rebuild for other versions with `make octave`, `make matlab` or `make python`, or `pip install psychmetal`. Restart Octave or MATLAB before switching native builds after opening a graphics window.

On the tested 6016×3384, 60 Hz display, the readback test (15/15), the hardware test and the inventory test passed in every host: Python 3.14 (169/169 checks across 53 commands), Octave 11.3.0 and MATLAB R2026a (166/166 across 51 each), with identical readback figures in all three. The 0.5.1 wheel installed from PyPI also passed the Python inventory test (169/169), under Python 3.14.

Timing rests on Metal presentation reports. 0.4.3's timing validation has not been repeated since, and no version has been validated with a photodiode; no physical input-to-photon accuracy or universal frame-rate guarantee is claimed.

Readback verifies the frame handed to the display, not what the display does with it. Two cases found while testing, with every frame reading back exact: a display link that compresses the picture (Display Stream Compression) alters stimuli that hold more information than its bit budget, such as single-pixel colored noise, and a change in one region then alters static texture below it in the same slice; and liquid-crystal pixels that change on every frame can emit less light than pixels at rest. The package README describes both.
