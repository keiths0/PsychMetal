# PsychMetal 0.8.1 validation — October 10, 2026

All available automated checks passed against the finalized 0.8.1 sources.
GitHub release preparation is complete; no App Store upload is included.

## Completed checks

- Rebuilt ARM64 Octave, MATLAB and Python native modules with matching 0.8.1
  versions. Real macOS, iOS device and ARM64 simulator SDK type checks passed.
- Full regression runner passed, including both host bindings against the
  scripted engine. Octave inventory: **237/237 checks across 78 commands**;
  readback: **46/46**. Python demos, phone menu/report tests, custom shader
  validation, cancellation and adaptive wait tests passed.
- Native sanitizer checks cover input/resource lifetime, timeline samples,
  cancellation, keyframes/live updates, image layouts, masks and shader wrappers.
- Sharing tests cover missing dismissal callbacks, menu restoration, preserved
  temporary files, stale timers, iPad anchors and starting a demo after sharing.
  Diagnostic gating removes optional tasks and reports without losing saved data.
- The user confirmed full-width sharing on a physical iPhone and subsequently
  confirmed the cancellation freeze was fixed. On October 10 the user also
  confirmed final-build sharing, cancellation, subsequent demo launch and saving
  a report to Files worked. Mocked UIKit tests remain separate from device results.
- Fresh Python 3.14 Mac, iOS device and ARM64 simulator wheels and a source
  distribution were built. The Mac wheel was loaded from an isolated install;
  wrapper and native engine both report 0.8.1.
- Briefcase sources and dependencies were refreshed and Xcode preparation rerun.
  Both unsigned Release app builds succeeded. Offline verification passed for
  each: **88 compatible frameworks**, version 0.8.1/build 1, matching source and
  shader assets, app privacy manifest, and no static archives. OpenSSL module
  privacy manifests and framework signatures passed separate verification.
- Current documentation, package metadata, app screens and GitHub workflow paths
  target 0.8.1. Historical changelog entries retain their original version numbers.
- Release manifests, per-file checksums and archive/asset checksums were refreshed.

## Limits and remaining acceptance

This execution environment has no accessible Metal GPU or active display.
Metal pixel fixtures compiled but explicitly skipped execution. Simulator and
physical-device launch are unavailable here; unsigned builds and offline privacy
checks are not a signed App Store archive or Apple's server-side validation.
Remote Linux/macOS CI must pass on the final release commit before publication.

The sharing/cancellation/demo-launch/report-export smoke test passed on the
user's iPhone. Additional hardware acceptance includes diagnostics hide/show,
About version, touch/three-finger exit and background/resume. Run timing
from the Home Screen with Xcode disconnected; run Main Thread Checker separately.

The broader hardware matrix includes MATLAB/Octave/Python on the same Mac,
60 Hz and high-refresh displays, native-pixel/HiDPI and multiple-monitor selection,
iPhone/iPad in both orientations, and background/resume. Earlier isolated visual
acceptance does not establish all-host or all-shader coverage.

Presentation timestamps and GPU pixels do not prove emitted-light timing;
photodiode validation is required for those claims. The supplied Octave binary
uses Octave 11.3 libraries requiring macOS 26; MATLAB/Python target macOS 14+.
Video/audio remain deferred. GitHub release and Apple submission are separate.
