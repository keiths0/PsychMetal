# PsychMetal

Native Metal stimulus presentation for Apple Silicon macOS, with MATLAB, Octave and Python interfaces. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.5.1

- [Download the 0.5.1 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.5.1)
- [Installation, build instructions and demos](PsychMetal-0.5.1/README.md)
- [Changelog](PsychMetal-0.5.1/CHANGELOG.md)
- [Design: one engine, MATLAB/Octave and Python front ends](PsychMetal-0.5.1/DESIGN-0.5.0.md)
- [Keyboard queue](PsychMetal-0.5.1/KEYBOARD-QUEUE.md)

Version 0.5.1 adds frame readback: a window opened with `readback` copies each frame's own drawable before it is presented, and `GetImage` (`get_image` in Python) returns those pixels, so a program can check what the GPU rendered. It also packs uint8 and logical textures several times faster, with the same result bit for bit, and removes two engine commands that nothing called. The presentation and timing path is otherwise that of 0.5.0. Python: [`pip install psychmetal`](https://pypi.org/project/psychmetal/).

Binaries are included for Octave 11.3.0 (Homebrew), MATLAB R2026a and Python 3.14 on Apple silicon; for other versions, rebuild with `make octave`, `make matlab` or `make python`. On the tested 6016×3384, 60 Hz display, the readback test (15/15), the hardware test and the inventory test passed in every host: Python (169/169 checks across 53 commands), Octave and MATLAB (166/166 across 51 each). 0.4.3's timing validation has not been repeated since. Metal timestamps have not been validated with a photodiode, in any version; no physical input-to-photon accuracy or universal frame-rate guarantee is claimed. Readback verifies the rendered frame, not what the display link or panel does with it; the package README gives two cases it cannot see.

## Previous releases

Version 0.5.0 ([folder](PsychMetal-0.5.0/README.md), [changelog](PsychMetal-0.5.0/CHANGELOG.md)) added the Python interface on the same native engine as MATLAB and Octave, and `DrawTextures`.

Version 0.4.3:

- [Download the 0.4.3 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.4.3)
- [Installation, demos and build instructions](PsychMetal-0.4.3/README.md)
- [Validation and timing limitations](PsychMetal-0.4.3/VALIDATION.md)

The final Octave build of 0.4.3 passed all 151 inventory checks across 49 commands and 10/10 repeated-open/first-stimulus checks on the tested display. The supplied Octave binary links Homebrew Octave 11.3.0; other installations may require rebuilding.

Add only one version folder to your host path, not its tests/mock subdirectory. Restart Octave/MATLAB before switching native builds after opening graphics.

## History and comparisons

The 0.4.3 changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](PsychMetal-0.5.1/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
