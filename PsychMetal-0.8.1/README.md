# PsychMetal 0.8.1

Native Metal presentation shared by MATLAB, Octave, Python and the iPhone/iPad app.
The 0.7.1 App Store submission's source is at tag v0.7.1.

Included: native environment metadata and JSON export through all three Mac
interfaces, and native captured-scene timeline playback through all three
interfaces. See [TIMELINE.md](TIMELINE.md) and the new Python/MATLAB/Octave timeline
demos. Reusable analytic Gaussian/ellipse/annulus/raised-cosine masks are implemented;
see [GPU-MASKS.md](GPU-MASKS.md). Masked still-image drawing and draggable
Mac/phone demos are implemented; see [MASKED-IMAGES.md](MASKED-IMAGES.md).
Native keyframes and live parameter updates are implemented; see TIMELINE.md.
Custom fragment programs and the shared spiral demo are documented in
[CUSTOM-SHADERS.md](CUSTOM-SHADERS.md). The phone app retains timing reports and
matching environment metadata locally, with an explicit system Share sheet.
Video and audio are deferred to future releases. Physical GPU/device acceptance
remains required; see VALIDATION.md.

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

Build the Mac modules with `make all PYTHON=/path/to/arm64/python`. Current local
builds are ARM64: MATLAB/Python target macOS 14+, Octave uses the installed 11.3
libraries requiring macOS 26. The phone build uses fresh 0.8.1 device and simulator wheels; no earlier-version
wheels are copied into this tree. Generated Xcode projects are build outputs,
not source files. See phone/README.md for rebuilding.

Further API documentation is in GPU-STIMULI.md, DISPLAY-MODES.md, DISPLAY-LINK.md
and READBACK.md.
