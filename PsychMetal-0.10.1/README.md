# PsychMetal 0.10.1


New in 0.10.1: [relative-linear HDR/EDR](HDR.md), [prepared GPU
image-processing chains](IMAGING.md) and [online PCM buffer refilling](AUDIO.md#online-pcm-refilling-0101).
Three matching Python/MATLAB/Octave demos are included, and the Python demos
are in the phone app. Mac GPU pixel checks and Mac/phone functional checks
passed. See [VALIDATION.md](VALIDATION.md) for evidence and remaining coverage
limits. See [release notes](RELEASE-0.10.1.md) for compatibility and scope.

Native Metal presentation and Core Audio sound, shared by MATLAB, Octave,
Python and the iPhone/iPad app. The 0.7.1 App Store submission's source is at
tag v0.7.1.

Introduced in 0.10.0: frame-indexed movie playback, movie audio, stimulus recording,
and analytic arcs. An opt-in virtual recording clock supports Flip loops and
generated audio, queued/native playback and standalone offscreen export;
see [DEVELOPMENT-0.10.1.md](DEVELOPMENT-0.10.1.md).

Introduced in 0.9.0: audio. Sounds start and stop on the sample nearest a GetSecs time
or a queued frame's projected presentation, can be amplitude-modulated on the
same clock, and are reported with the times they played. Input records on exact
samples, with a one-shot voice key and a live monitor. See [AUDIO.md](AUDIO.md)
and two new demos: a live spectrogram with a recorder (`python/audio_demo.py`,
`PsychMetalAudioDemo.m`) and phase and frequency matching between a flickering
blob and a modulated tone (`python/modulation_match_demo.py`,
`PsychMetalModulationMatchDemo.m`). Both are in the phone app. Audio times are
the times the system reports; they have not yet been measured on hardware.

Also included: native environment metadata and JSON export through all three
Mac interfaces, and native captured-scene timeline playback through all three
interfaces, with keyframes and live parameter updates; see
[TIMELINE.md](TIMELINE.md). Reusable analytic Gaussian/ellipse/annulus/
raised-cosine masks are in [GPU-MASKS.md](GPU-MASKS.md); masked still images and
draggable Mac/phone demos in [MASKED-IMAGES.md](MASKED-IMAGES.md); custom
fragment programs and the shared spiral demo in
[CUSTOM-SHADERS.md](CUSTOM-SHADERS.md). The phone app retains timing reports and
matching environment metadata locally, with an explicit system Share sheet.
Movie playback and stimulus recording are included; see [MOVIES.md](MOVIES.md). Broader GPU/device acceptance remains required;
see VALIDATION.md.

```python
import psychmetal as pm
print(pm.environment_report())
pm.export_environment_report('psychmetal-environment.json')
```

```matlab
report = PsychMetal('Environment');
PsychMetal('ExportEnvironment', 'psychmetal-environment.json');
```

Environment collection requires no open window. Both accept an optional window
handle to include presentation configuration and diagnostics; that can wait for
GPU work, so collect it outside the stimulus loop. JSON export creates a new file.

Build the Mac modules with `make all PYTHON=$(which python3)`, where that
Python is an ARM64 one (`python3 -c "import platform; print(platform.machine())"`
prints `arm64`), then `make test PYTHON=$(which python3)`. The build compiles
the built-in shaders with Xcode's Metal compiler; with Xcode 26 or later install
it once with `xcodebuild -downloadComponent MetalToolchain`. Current local builds
are ARM64: MATLAB/Python target macOS 14+, Octave uses the installed 11.3
libraries requiring macOS 26. The phone build uses fresh 0.10.1 device and
simulator wheels; no earlier-version wheels are copied into this tree. Generated
Xcode projects are build outputs, not source files. See phone/README.md for
rebuilding.

Further API documentation is in AUDIO.md, GPU-STIMULI.md, DISPLAY-MODES.md,
DISPLAY-LINK.md and READBACK.md.

Introduced in 0.10.0: [standalone Metal movie export](OFFSCREEN-EXPORT.md) renders
without a presentation window, using the same drawing engine. Physical GPU/codec
coverage remains limited; see VALIDATION.md.

Additional 0.10.0 features: bounded movie lookahead
and full preload (`PrepareMovie` / `prepare_movie`), all-intra conversion
(`TranscodeMovie` / `transcode_movie`), keyframe spacing and reported A/V offsets,
private static textures, direct float32 uploads on compatible GPUs, confirmed
startup without a fixed one-second delay, and Mac audio device recovery.
See [WISHLIST-0.10.0.md](WISHLIST-0.10.0.md) for APIs and validation limits.
