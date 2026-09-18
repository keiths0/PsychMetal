# PsychMetal

Native Metal stimulus presentation for Apple Silicon macOS, with Octave and MATLAB interfaces. Uses supported Screen-style argument formats; it is not a complete Psychtoolbox replacement. No OpenGL or Vulkan presentation backend is used.

## Current release: 0.4.3

- [Download the release](https://github.com/keiths0/PsychMetal/releases/tag/v0.4.3)
- [Installation, demos and build instructions](PsychMetal-0.4.3/README.md)
- [Changelog, including 0.4.1 and 0.4.2](PsychMetal-0.4.3/CHANGELOG.md)
- [Validation and timing limitations](PsychMetal-0.4.3/VALIDATION.md)
- [Keyboard queue](PsychMetal-0.4.3/KEYBOARD-QUEUE.md)

Version 0.4.3 improves image uploads, native input validation, texture/resource lifetime, keyboard polling and startup readiness. OpenWindow confirms two background presentations before returning. The final Octave build passed all 151 inventory checks across 49 commands and 10/10 repeated-open/first-stimulus checks on the tested 6016×3384, 60 Hz display. See the validation record for separate optimization-stage measurements.

Metal timestamps have not been validated with a photodiode. No physical input-to-photon accuracy or universal frame-rate guarantee is claimed. MATLAB binaries are included but have not received equivalent hardware testing. The supplied Octave binary links Homebrew Octave 11.3.0; other installations may require rebuilding.

Add only the version folder to your host path, not its tests/mock subdirectory. Restart Octave/MATLAB before switching native builds after opening graphics.

## History and comparisons

The changelog retains 0.4.1's demo/signature fixes, included in the published 0.4.2 package. Historical version folders and [development reports](docs/) remain available; their measurements and implementation descriptions refer to their original versions. Optional Psychtoolbox comparisons are in [comparisons/](PsychMetal-0.4.3/comparisons/).

## License and citation

[MIT license](LICENSE). See [CITATION.cff](CITATION.cff). Original demo attribution is retained in the source.
