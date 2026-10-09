# Validation of PsychMetal 0.7.1 — 8 October 2026

## Completed

- Native ARM64 Octave, MATLAB and Python modules built; device and simulator
  Python 3.14 wheels built. Real engine SDK type checks passed for macOS, iOS
  and the iOS simulator with Wall/Wextra/Wpedantic.
- The final scripted-engine front-end suite passed, including Python argument
  contracts, reusable readback buffers, measured/fractional-refresh blob samples,
  dragging, phone catalogue/navigation/report retention, and timing analysis.
  Octave inventory: 222/222 checks; readback: 46/46.
- Native display-link handoff/submission tests passed: fresh update delivery,
  discarded idle/early callbacks, cancellation, commit-then-present ordering,
  and rejection of timed presentation on linked drawables.
- Portrait and landscape annulus tests cover square clipping, black full-window
  clearing, movement into the margins, both grain sizes, scrolling and grain
  alignment. The scripted engine checks procedural command contracts, not GPU
  noise pixels.
- Unsigned iPhone Release Xcode build succeeded. Bundled source/artwork and both
  native device/simulator wheel packages were verified against the source.
- The user accepted the final iPhone menu and stimuli. The user reported no long
  frame intervals after stopping Xcode debugging and disconnecting the phone.
  Earlier captured frames around visible glitches were reported to look correct.

## Limits and distribution

The complete hardware runner cannot pass in this execution environment: its
real display-enumeration test reports `No active displays`; later real-GPU checks
were not reached. SDK builds, mock tests and native handoff tests do not replace
GPU pixel validation, live MATLAB acceptance or tests across all devices.
The prior readback/GPU timing observations are not a universal throughput claim.

No photodiode, physical input-to-photon, exhaustive variable-refresh or
multi-display validation is claimed. Frame capture is synchronous and can
perturb timing. Software timestamps are not physical light onset measurements.
The Octave binary depends on the build machine's Octave installation; rebuild
if the supplied module does not load with your installation.

The GitHub release includes Mac binaries, source, phone build materials and
separate device/simulator iOS wheels. It is not a signed App Store archive.
App Store screenshots, support/privacy hosting, signed archive/privacy review,
TestFlight and App Store submission remain separate work.

Historical 0.4.3 validation is retained in ../PsychMetal-0.4.3/VALIDATION.md.
