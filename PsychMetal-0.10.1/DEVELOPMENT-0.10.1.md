# PsychMetal 0.10.1 release checks — October 16, 2026

Release prepared October 16, 2026. Published 0.10.0 is unchanged.
PyPI and App Store publication are separate.

Implemented in the shared native engine and Python/MATLAB/Octave front ends:

- Relative-linear HDR/EDR presentation, floating uploads/readback, dynamic
  headroom and scene exposure; see HDR.md.
- Prepared GPU image chains with Gaussian blur, exposure, matrices, convolution
  and inverse affine resampling; see IMAGING.md.
- Preallocated online PCM streams with bounded refills, EOS and underflow
  counters; see AUDIO.md. Existing modulation matching keeps callback-based
  sample-timed modulation of a preloaded carrier.
- New cross-platform demos and phone menu entries for all three features.
  HDR includes a circular 7x7 pairwise flicker grid and smaller steady circular
  references, adjustable equal whole-frame holds from the measured refresh
  grid (16 Hz default target), constant diagonal controls and an invariant
  global histogram. In-demo touch/mouse/keyboard controls
  apply changes only at complete-cycle boundaries.
  iOS buttons consume queued touch-down events rather than the two-finger
  mouse-button emulation. Tests cover short taps, secondary fingers, cancelled
  gestures and dropped-event batches.
  Python/Octave fixtures check 59.94/60/75/96/120 Hz, layouts, controls and alpha edges.
- Fixed an offline recording stop/append race exposed by sanitizer testing:
  one stop snapshot now governs both final-horizon rendering and worker exit.
  Deterministic tests stop inside the append callback to verify the audio tail.
- Filtered outputs retain GPU snapshots and refuse unsafe partial CPU updates;
  HDR masks retain 0..1 coverage and movie operations explicitly refuse HDR.

Verification:

- Real Python/MEX bindings against the scripted engine: inventory 295/295
  checks over 114 commands, readback 46/46; Python demos and Octave demos.
- Actual streaming mixer/ring buffer: ASan/UBSan and ThreadSanitizer, including
  wraparound, concurrent refills, underflow/recovery and end-of-stream.
- Actual HDR pack/unpack and imaging-program preparation: sanitizer fixtures.
- macOS, iOS device and iOS simulator SDK typechecks with compiler warnings.
- Mac Octave, MATLAB and Python 3.15 native modules; Python 3.14 device/simulator
  wheels; unsigned device app build and bundle/privacy verification.
- Regression run used --skip-media-fixtures. GPU pixel fixtures compile but
  explicitly skip because this execution environment exposes no Metal device.
  These skips do not establish GPU rendering or codec acceptance.

Keith completed the Mac checks and confirmed the Mac and phone demos work.
See VALIDATION.md for the supplied hardware results. Broader device coverage,
HDR display readback beyond the existing SDR/10-bit checks, alpha/affine edge
cases and codec/conversion throughput remain outside this acceptance run.
No photodiode or absolute timing/brightness claims.

Final regression repeat completed successfully on October 16 with explicit
--skip-media-fixtures (295 inventory and 46 readback checks). New noise-selector
and phone UI tests are included. GPU fixtures skipped here; Keith's physical
imaging GPU fixture passed. Python 3.14 Mac wheel and source archive prepared;
wheel import/version, current sources and source-archive contents verified.
