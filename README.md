# PsychMetal

Native Metal stimulus presentation for Apple silicon Macs with MATLAB, Octave and Python interfaces, and for iPhone/iPad with Python. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.7.1

- [Download the 0.7.1 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.7.1)
- [Installation, build instructions and demos](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/README.md)
- [Changelog](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/CHANGELOG.md)
- [Design: one engine, MATLAB/Octave and Python front ends](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/DESIGN-0.5.0.md)
- [Keyboard queue and input event times](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/KEYBOARD-QUEUE.md)

Version 0.7.1 optimizes frame readback, adds reusable Python output arrays,
uses measured-rate frame-count sampling for the draggable blob array, and
provides the phone demo gallery with scrollable timing reports. iPhone uses
CAMetalDisplayLink by default. See [presentation](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/DISPLAY-LINK.md),
[readback](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/READBACK-0.7.1.md), and [validation](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/VALIDATION.md).

The user accepted the phone visuals and reported no long intervals after
stopping Xcode debugging. Metal timestamps have not been validated with a
photodiode. The GitHub ZIP includes Mac MATLAB/Octave binaries and phone source;
separate iOS wheels are release assets. Python Mac wheels follow the repository’s
existing PyPI release workflow. The phone app is not yet distributed through
the App Store; see [phone build instructions](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/phone/README.md).

## Previous releases

Version 0.7.0 ([release](https://github.com/keiths0/PsychMetal/releases/tag/v0.7.0), [changelog](PsychMetal-0.7.0/CHANGELOG.md)) introduced the iPhone/iPad Python port, reusable GPU carriers and masks, touch events and the draggable Gaussian array.

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

The 0.4.3 changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](https://github.com/keiths0/PsychMetal/blob/v0.7.1/PsychMetal-0.7.1/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
