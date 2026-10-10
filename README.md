# PsychMetal

Native Metal stimulus presentation for Apple silicon Macs with MATLAB, Octave and Python interfaces, and for iPhone/iPad with Python. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current version: 0.8.0

- [Download PsychMetal 0.8.0](https://github.com/keiths0/PsychMetal/releases/tag/v0.8.0)
- [Installation, build instructions and demos](PsychMetal-0.8.0/README.md)
- [Changelog](PsychMetal-0.8.0/CHANGELOG.md)
- [Validation and hardware limitations](PsychMetal-0.8.0/VALIDATION.md)

Version 0.8.0 adds native captured-scene timelines with periodic tracks, keyframes
and Python live controls; analytic GPU masks and masked still images; custom Metal
fragment programs; and persistent phone reports with explicit sharing. It also
improves input concurrency, presentation reporting and column-major image uploads.
Gabor orientation now agrees with procedural gratings; zero-width mask edges are
exactly hard. See the changelog for these behavior changes.

Mac MATLAB/Octave binaries, source and demos are in the ZIP. Python 3.14 ARM64 Mac
and iOS device/simulator wheels are separate release assets. The supplied Octave
binary uses Octave 11.3 libraries requiring macOS 26; MATLAB/Python target macOS 14+.
Automated checks do not establish physical timing or complete cross-device GPU
acceptance. The GitHub release does not change the separate 0.7.1 App Store submission.
Video and audio remain deferred.

## Previous releases

Version 0.7.1 ([release](https://github.com/keiths0/PsychMetal/releases/tag/v0.7.1)) optimized readback and introduced the phone gallery and timing reports. Its source is preserved at the release tag.

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
