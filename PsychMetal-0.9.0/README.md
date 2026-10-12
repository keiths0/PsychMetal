# PsychMetal 0.9.0

Native Metal presentation, and now Core Audio sound, shared by MATLAB, Octave,
Python and the iPhone/iPad app. The 0.7.1 App Store submission's source is at
tag v0.7.1.

New in 0.9.0: audio. Sounds start and stop on the sample nearest a GetSecs time
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
Video is deferred to 0.10.0. Physical GPU/device acceptance remains required;
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
libraries requiring macOS 26. The phone build uses fresh 0.9.0 device and
simulator wheels; no earlier-version wheels are copied into this tree. Generated
Xcode projects are build outputs, not source files. See phone/README.md for
rebuilding.

Further API documentation is in AUDIO.md, GPU-STIMULI.md, DISPLAY-MODES.md,
DISPLAY-LINK.md and READBACK.md.
