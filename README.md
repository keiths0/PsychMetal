# PsychMetal

Native Metal stimulus presentation for Apple Silicon macOS, with MATLAB, Octave and Python interfaces. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.5.0

- [Installation, build instructions and demos](PsychMetal-0.5.0/README.md)
- [Changelog](PsychMetal-0.5.0/CHANGELOG.md)
- [Design: one engine, MATLAB/Octave and Python front ends](PsychMetal-0.5.0/DESIGN-0.5.0.md)
- [Keyboard queue](PsychMetal-0.5.0/KEYBOARD-QUEUE.md)

Version 0.5.0 adds a Python interface (`import psychmetal`) on the same native engine as MATLAB and Octave, with every PsychMetal command, numpy images read without copying, and Python versions of every demo and hardware check. It also adds `DrawTextures`, which draws many textures in one call, as Screen's does. The presentation, timing, texture and input internals are those validated for 0.4.3.

Binaries are included for Octave 11.3.0 (Homebrew), MATLAB R2026a and Python 3.14 on Apple silicon; for other versions, rebuild with `make octave`, `make matlab` or `make python`. On the tested 6016×3384, 60 Hz display, the full regression suite passed, and the inventory tests passed in every host: Octave 153/153 and MATLAB 153/153 checks across 50 commands, Python 156/156 across 52. 0.4.3's timing validation has not yet been repeated under 0.5.0. Metal timestamps have not been validated with a photodiode, in any version; no physical input-to-photon accuracy or universal frame-rate guarantee is claimed.

## Previous release: 0.4.3

- [Download the 0.4.3 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.4.3)
- [Installation, demos and build instructions](PsychMetal-0.4.3/README.md)
- [Validation and timing limitations](PsychMetal-0.4.3/VALIDATION.md)

The final Octave build of 0.4.3 passed all 151 inventory checks across 49 commands and 10/10 repeated-open/first-stimulus checks on the tested display. The supplied Octave binary links Homebrew Octave 11.3.0; other installations may require rebuilding.

Add only one version folder to your host path, not its tests/mock subdirectory. Restart Octave/MATLAB before switching native builds after opening graphics.

## History and comparisons

The 0.4.3 changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](PsychMetal-0.5.0/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
