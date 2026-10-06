# PsychMetal

Native Metal stimulus presentation for Apple Silicon macOS, with MATLAB, Octave and Python interfaces. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.6.0

- [Download the 0.6.0 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.6.0)
- [Installation, build instructions and demos](PsychMetal-0.6.0/README.md)
- [Changelog](PsychMetal-0.6.0/CHANGELOG.md)
- [Design: one engine, MATLAB/Octave and Python front ends](PsychMetal-0.6.0/DESIGN-0.5.0.md)
- [Keyboard queue and input event times](PsychMetal-0.6.0/KEYBOARD-QUEUE.md)

Version 0.6.0 adds drawing in linear light (`Linearize`, by a gamma or a measured table, with a gamma calibration by eye), 10-bit frames, additive and copy blending, text in one or several lines, polygons, a clip rect, offscreen windows, updating part of a texture, a report of the display link and whether it is compressed, and a display test. A frame the display never showed is now reported (`FlipInfo`) instead of stopping the program. Two additions are designs whose timing has not been measured: frames queued ahead of time (`QueueFlip`), and key and mouse-button times taken from the events themselves where Input Monitoring is allowed. Python: [`pip install psychmetal`](https://pypi.org/project/psychmetal/), where `with pm.open_window(...) as (w, rect, ifi):` now closes the window however the block ends.

Binaries are included for Octave 11.3.0 (Homebrew), MATLAB R2026a and Python 3.14 on Apple silicon; for other versions, rebuild with `make octave`, `make matlab` or `make python`. On the tested 6016×3384, 60 Hz display, from Python and from Octave, the readback test (46/46) and the inventory test (220/220 checks across 68 commands in Python, 218/218 across 66 in Octave) passed. The MATLAB binary builds, and its tests have run only against a scripted engine, not on the display. 0.4.3's timing validation has not been repeated since. Metal timestamps have not been validated with a photodiode, in any version; no physical input-to-photon accuracy or universal frame-rate guarantee is claimed. Readback verifies the rendered frame, not what the display link or panel does with it.

## Previous releases

Version 0.5.1 ([release](https://github.com/keiths0/PsychMetal/releases/tag/v0.5.1), [folder](PsychMetal-0.5.1/README.md), [changelog](PsychMetal-0.5.1/CHANGELOG.md)) added frame readback (`GetImage`) and a faster upload of uint8 textures.

Version 0.5.0 ([folder](PsychMetal-0.5.0/README.md), [changelog](PsychMetal-0.5.0/CHANGELOG.md)) added the Python interface on the same native engine as MATLAB and Octave, and `DrawTextures`.

Version 0.4.3:

- [Download the 0.4.3 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.4.3)
- [Installation, demos and build instructions](PsychMetal-0.4.3/README.md)
- [Validation and timing limitations](PsychMetal-0.4.3/VALIDATION.md)

The final Octave build of 0.4.3 passed all 151 inventory checks across 49 commands and 10/10 repeated-open/first-stimulus checks on the tested display. The supplied Octave binary links Homebrew Octave 11.3.0; other installations may require rebuilding.

Add only one version folder to your host path, not its tests/mock subdirectory. Restart Octave/MATLAB before switching native builds after opening graphics.

## History and comparisons

The 0.4.3 changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](PsychMetal-0.6.0/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
