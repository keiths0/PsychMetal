# PsychMetal 0.8.0

Native Metal stimulus presentation for Apple Silicon Macs (Python, MATLAB and
Octave) and iPhone/iPad (Python), using one shared engine.

## New capabilities

- Captured-scene native timelines with frame-counted periodic tracks and linear
  keyframes. Python controllers can read input and update procedural parameters
  while playback runs, with atomic updates and cancellation.
- Reusable Gaussian, ellipse, annulus and raised-cosine masks; masked still-image
  drawing with cropping, rotation, filtering, tint and combined coverage.
- Custom Metal fragment programs with upfront pipeline compilation, a fixed
  parameter contract and a shared spiral demonstration across host languages.
- Environment reports, persistent phone timing reports and explicit iPhone/iPad
  sharing. Idle main-thread Python collection addresses a likely UIKit cleanup
  cause; real-device lifecycle acceptance remains outstanding.
- Faster Octave wrapper calls and tiled column-major image uploads. Timeline
  results distinguish submitted samples from reported presentations and lateness.

## Behavior changes

Gabor orientation now agrees with procedural gratings (clockwise from screen
right), changing non-horizontal Gabor patterns relative to 0.7.x. Edge-zero masks
and ellipse apertures are exactly hard rather than antialiased. Timeline result
fields changed; see TIMELINE.md. MATLAB/Octave expose blocking playback/keyframes
and Escape cancellation; live controls are Python/native APIs.

## Downloads and validation

The ZIP includes source, Mac MATLAB/Octave binaries, Python package/demos, phone
build resources and device/simulator wheels. Separate assets include the Python
3.14 ARM64 Mac wheel, source archive and iOS wheels. MATLAB/Python target macOS
14+; the supplied Octave 11.3 module needs macOS 26 and matching Octave libraries.
Other Python versions can build from source; the repository wheel workflow also
builds supported CPython versions. See README.md for installation.

Local regression suite: 233/233 inventory checks across 76 commands and 46/46
readback checks; native sanitizer and concurrency tests pass. All three Mac
modules and both iOS wheels rebuilt; device and simulator Release builds and
88-framework bundle/privacy inspections pass. GPU fixtures were explicitly
skipped without an accessible Metal device. Physical timing, complete cross-device
GPU visuals and real UIKit sharing/lifecycle remain unverified; see VALIDATION.md.
Software timestamps do not certify emitted-light timing.

Video/audio are deferred. This GitHub release does not alter or upload the
separate 0.7.1 App Store submission. PyPI publication remains a separate explicit
manual action.
