# Local validation — October 8, 2026

Passed:
- Native MATLAB, Octave and Python builds.
- iOS device and simulator wheels; inspected native binaries to verify the current engine is present, rather than an earlier cached engine build.
- Real macOS/iOS/simulator SDK type checks.
- Python/Octave front-end suite against the scripted engine.
- Phone input mapping tests and public-menu/help/privacy/navigation tests.
- Device Release configuration Xcode build with local ad-hoc embedded-framework
  signing and distribution signing disabled. This is not a signed App Store archive.
- Checked the built app contains the privacy manifest, public source, offline
  documents, new native binary, app configuration and original RGB icons.
- Checked that repeated resource preparation does not duplicate project entries.

Not performed:
- Device visual/touch acceptance of the public menu and three-finger exit.
- App Store screenshot capture, public support/privacy-page hosting.
- Signed archive validation, aggregate dependency privacy review, export-compliance
  declaration, TestFlight upload, external beta review or App Store submission.

The local environment cannot run a live iPhone display. Successful builds and
scripted tests do not establish on-device timing, accessibility or visual quality.

The stimulus overlay was subsequently removed at the user’s request. Three-finger exit remains the return gesture.

### 2026-10-08: measured-rate blob sampling and audit fixes

- Python and MATLAB/Octave use confirmed startup refresh measurements and even
  integer frame periods, including a six-frame waveform. Precomputed samples
  include both extrema; labels use the measured rate to two decimal places.
- Full scripted front-end suite passed, including fractional-refresh calibration,
  refusal of insufficient calibration, mouse/touch interaction, phone reports,
  inspector controls, and the real MEX wrapper against the mock engine.
- Phone reports use confirmed presentation timestamps. The captured-frame
  inspector respects safe-area insets and uses ordinary sleep while paused.
- Device and simulator wheels rebuilt; Briefcase bundle source verified against
  the edited files. Unsigned iPhone Release Xcode build succeeded.
- Physical iPhone/display timing and visual acceptance remain to be tested.

### 2026-10-08: experimental display-link comparison

- Added shared CAMetalDisplayLink backend, exposed through Python and
  MATLAB/Octave OpenWindow options. Direct remains the default.
- Native handoff test passed without a GPU: fresh-update delivery, rejection of
  unused/early callbacks, and cancellation wake-up.
- Engine SDK type checks passed for macOS, iOS, and the iOS simulator.
- Scripted Python/Octave integration suite passed, including backend selection,
  unsupported-operation rejection, reopen, and the combined phone comparison
  with no image capture. Octave inventory: 222/222; readback: 46/46.
- Full regression runner stopped at the existing real Python display-enumeration
  check with `No active displays` in this execution environment. This is not a
  completed hardware validation; later GPU checks in that runner were not run.
- Mac front ends, device/simulator wheels, and unsigned iPhone Release app built.
  Bundled app source and device binary verified against the edited source/wheel.
- Physical phone comparison still required; no glitch reduction claimed.

### 2026-10-08: display-link startup crash correction

Device exception identified the exact error: `-presentAtTime should not be
called when using CAMetalDisplayLink.` The shared submission helper now commits
rendering and calls the drawable's `present` for display-link frames; timed
command-buffer presentation remains exclusive to direct mode. A native test
verifies both dispatch and call order. It passes, as do the full scripted
front-end suite, app routing/no-capture checks, and three-platform SDK checks.

Phone Diagnostic mode now sets inspect_frames=False for both blob-array modes;
menu explanations updated. Device/simulator wheels, Mac front ends, and unsigned
iPhone Release Xcode app rebuilt. Bundled native device binary and phone source
verified. The corrected app still requires a physical-device retry.

### 2026-10-08: recurrence diagnostics

Added per-long-interval detail, previous/current CPU/GPU work, whole-second phase,
and bounded Python collection spans. Scripted integration and synthetic event
alignment tests passed, including retained-history suffixes, collection overlap,
buffer overflow, and callback cleanup on errors. Existing phone comparison still
asserts no image capture. Unsigned iPhone Release Xcode build succeeded and the
bundled frame_timing source matches the edited file. Physical recurrence cause
remains undetermined; instrumented phone output is required.

### Final 0.7.1 release acceptance — 2026-10-08

The final user phone run accepted the gallery, centered Gabor/psychometric
header, demos and touch interaction. After disconnecting Xcode the user
reported no long frame intervals. Current app defaults to CAMetalDisplayLink;
the two presentation-comparison demos were removed. Diagnostic mode reveals
only Frame timing and never captures/pause-inspects frames. Full text output
has a separate scrolling page. Noise-annulus backgrounds use a fixed centered
square with black margins in portrait and landscape.

Final front-end suite, menu/report tests and annulus layout/clip tests passed;
unsigned iPhone Release build succeeded. Bundled source, artwork and native
wheels matched their source files. These results supersede earlier pending
phone-acceptance/default-backend statements above. App Store archive validation,
screenshots, hosting and submission are still pending.
