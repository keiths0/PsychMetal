# PsychMetal

Native Metal stimulus presentation for Apple silicon Macs with MATLAB, Octave and Python interfaces, and for iPhone/iPad with Python. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.7.0

- [Download the 0.7.0 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.7.0)
- [Installation, build instructions and demos](PsychMetal-0.7.0/README.md)
- [Changelog](PsychMetal-0.7.0/CHANGELOG.md)
- [Design: one engine, MATLAB/Octave and Python front ends](PsychMetal-0.7.0/DESIGN-0.5.0.md)
- [Keyboard queue and input event times](PsychMetal-0.7.0/KEYBOARD-QUEUE.md)

Version 0.7.0 adds reusable GPU noise and gratings with independent masks, a Python engine port and demo app for iPhone/iPad, timestamped touch events, and a draggable array of counterphasing Gaussian blobs. See [GPU stimuli](PsychMetal-0.7.0/GPU-STIMULI.md), [iOS support and limitations](PsychMetal-0.7.0/IOS.md), and [the blob-array demo](PsychMetal-0.7.0/BLOB-ARRAY.md).

The iPhone port has run on an iPhone 18 Pro, but its timing has not been measured. The new blob array has automated waveform, layout and input tests; visual acceptance on a Mac and phone remains to be done. Historical display-validation results belong to the versions that report them. Metal timestamps have not been validated with a photodiode. The GitHub ZIP includes Mac MATLAB/Octave binaries; Python Mac wheels are published to PyPI. The iOS app and wheels are built separately using the [phone instructions](PsychMetal-0.7.0/phone/README.md).

## Previous releases

Version 0.6.0 ([release](https://github.com/keiths0/PsychMetal/releases/tag/v0.6.0), [changelog](PsychMetal-0.6.0/CHANGELOG.md)) added linear-light drawing, 10-bit frames, text, polygons, clipping, offscreen targets, queued presentation and input event timestamps.

Version 0.5.1 ([release](https://github.com/keiths0/PsychMetal/releases/tag/v0.5.1), [folder](PsychMetal-0.5.1/README.md), [changelog](PsychMetal-0.5.1/CHANGELOG.md)) added frame readback (`GetImage`) and a faster upload of uint8 textures.

Version 0.5.0 ([folder](PsychMetal-0.5.0/README.md), [changelog](PsychMetal-0.5.0/CHANGELOG.md)) added the Python interface on the same native engine as MATLAB and Octave, and `DrawTextures`.

Version 0.4.3:

- [Download the 0.4.3 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.4.3)
- [Installation, demos and build instructions](PsychMetal-0.4.3/README.md)
- [Validation and timing limitations](PsychMetal-0.4.3/VALIDATION.md)

The final Octave build of 0.4.3 passed all 151 inventory checks across 49 commands and 10/10 repeated-open/first-stimulus checks on the tested display. The supplied Octave binary links Homebrew Octave 11.3.0; other installations may require rebuilding.

Add only one version folder to your host path, not its tests/mock subdirectory. Restart Octave/MATLAB before switching native builds after opening graphics.

## History and comparisons

The 0.4.3 changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](PsychMetal-0.7.0/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
