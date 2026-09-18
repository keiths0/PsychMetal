# PsychMetal 0.4.3

PsychMetal provides native Metal stimulus presentation on Apple Silicon macOS, with a MATLAB/Octave interface resembling supported Psychtoolbox Screen commands. It uses no OpenGL or Vulkan presentation backend. It is experimental research software, not a complete Screen replacement.

## Install and run

Keep the entire folder together. In a fresh Octave session:

```matlab
addpath(fullfile(getenv('HOME'),'Desktop','PsychMetal','PsychMetal-0.4.3'),'-begin');
which PsychMetalCore
PsychMetalMinimalDemo(10)
```

Use the same addpath command in MATLAB. Adjust the path if installed elsewhere. Add only this folder, **not genpath**: tests/mock contains a deliberately fake core used by regression tests. Restart the host before switching native versions after graphics has been opened.

The supplied binaries are ARM64: PsychMetalCore.mex for Homebrew Octave 11.3.0 and PsychMetalCore.mexmaca64 built with MATLAB R2026a. They are ad-hoc signed, not notarized. The Octave binary depends on `/opt/homebrew/opt/octave/lib/octave/11.3.0/liboctmex.1.dylib`. Source targets macOS 14 or later, but the bundled Octave libraries were built for a newer macOS; rebuilding may be necessary for another host installation. MATLAB hardware operation has not been validated to the same extent as Octave.

## Drawing and input

Run `PsychMetal('?')` for the supported command list and `PsychMetal('DrawTexture?')` for command details. Check the command's help when porting Screen code; unsupported Screen features do not become available by renaming the function.

Drawing colors default to 0–255; `PsychMetal('ColorRange',w,1)` selects 0–1. Floating-point texture arrays use 0–1; uint8 uses 0–255. UpdateTexture updates texture data without creating a new public handle. Mouse and keyboard support are part of the main native MEX; no helper MEX is needed. See [KEYBOARD-QUEUE.md](KEYBOARD-QUEUE.md) for background key transitions and their polling limitations.

Useful demos: PsychMetalTextureDemo, PsychMetalGaborDemo, PsychMetalNoiseDemo, PsychMetalMouseRectDemo and PsychMetalKbQueueDemo. The standalone k-space teaching programs are not part of this package. Optional Psychtoolbox comparison programs are in comparisons/ and require Psychtoolbox.

## Timing and validation

OpenWindow confirms two consecutive background presentations before returning, keeping startup history separate from stimulus history. This removes unconfirmed startup presentations from the first user stimulus in the tested repeated-open cases. It does not eliminate the time required to initialize the window or guarantee every future frame.

Flip timing comes from Metal presentation reports, not a photodiode. Scheduled presentation is quantized by the display refresh. Read [VALIDATION.md](VALIDATION.md) for measured results and limitations and [CHANGELOG.md](CHANGELOG.md) for changes, including 0.4.1 and 0.4.2.

For manual hardware checks in a fresh host session:

```matlab
PsychMetalInventoryTest
report = PsychMetalOpenReadyTest;
report = PsychMetalMotionTest(1024);
report = PsychMetalMotionTest(2048);
```

These open full-screen windows. Motion-test panels must move right together with matching phase, orientation and brightness. Run tests from a writable working directory; reports are saved there. Automated checks do not substitute for visual inspection or physical onset measurement.

## Build and package

Install Apple's command-line build tools, Python 3 and the desired host toolchain. From this directory:

```bash
make octave
make matlab MATLAB_ROOT=/Applications/MATLAB_R2026a.app
make test
make package
```

`make package` verifies RELEASE-MANIFEST.txt and SHA256SUMS and stages the **existing** tested files into dist/PsychMetal. It does not rebuild binaries. If you deliberately change source or rebuild, the recorded checksums must be regenerated as part of a new validation/release cycle; do not bypass a mismatch to publish untested files.

## License and attribution

MIT; see [LICENSE](LICENSE). Original attribution in PsychMetalDotDemo.m is retained. Source, both host binaries, shader source, demos, regression tests and this release's documentation are included.
