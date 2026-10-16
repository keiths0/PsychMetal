# PsychMetal 0.10.0

Movies, stimulus recording and standalone Metal movie export now share the
same engine across Python, MATLAB/Octave and iPhone/iPad. Playback includes
frame-indexed drawing, bounded lookahead/full preload, movie audio, all-intra
conversion and reported A/V offsets. Virtual recording preserves intended
frame/sample timing through slow encoding; offscreen export needs no display
window. The phone adds playback, recording/replay, export/sharing and clearer
full-width Start controls. Analytic arcs, static/private textures, compatible
float32 uploads, startup confirmation and audio-device recovery are included.

## Downloads and compatibility

The ZIP contains source, demos, tests, documentation, MATLAB/Octave binaries,
the local Python 3.15 ARM64 Mac extension and both iOS wheels. A Python 3.14
ARM64 Mac wheel and source archive are separate assets. GitHub's wheel workflow
builds additional supported Python versions; publication to PyPI is a separate
explicit action. Add only this version folder to MATLAB/Octave's path.

MATLAB/Python: Apple silicon, macOS 14+. Supplied Octave binary: Octave 11.3,
macOS 26+. Toolbox iOS wheels: iOS 15+; phone demo app: iOS 17+.
Diagnostic now has 26 fields (adds displayCaptured); frame history remains 14
columns. Mac capture defaults on and can be opted out explicitly. Float32
precision depends on GPU filtering support. See CHANGELOG.md and the API docs.

## Validation limits

Available software checks pass (286 inventory, 46 readback), Mac/iOS builds
succeed, and the user functionally checked phone recording/replay/export and
UI. The current execution environment cannot execute GPU pixels or reliable
codec fixtures; successful conversion/preload across real codecs, throughput,
repeated startup, capture comparisons and physical endpoint recovery remain
unverified. Presentation/sample timestamps are not physical timing certification.
See VALIDATION.md for complete evidence. GitHub release does not upload the
phone app to Apple or publish Python packages to PyPI.
