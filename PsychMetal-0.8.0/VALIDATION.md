# 0.8.0 validation — October 10, 2026

Release validation record. All available automated regression checks passed;
physical GPU/device acceptance remains incomplete. This execution environment
has no accessible Metal GPU or active display.

## Completed checks

- Built a source distribution and a Python 3.14 Mac wheel; verified the wheel
  contains only ARM64 code with an ARM64 platform tag, installed it into an
  isolated temporary directory and loaded the engine/new APIs successfully.
- Rebuilt ARM64 Python, Octave and MATLAB native modules. Real macOS, iOS device
  and ARM64 simulator SDK type checks passed with warnings enabled.
- Full local regression runner passed, including both real host bindings against
  the scripted engine. Octave inventory **233/233 across 76 commands**; readback
  **46/46**. Both Python and MEX keyframe playback/validation passed.
- Actual native playback under AddressSanitizer/UndefinedBehaviorSanitizer:
  exact phase/extrema samples, contrast/translation, row/column-major, reversed
  and unaligned inputs, periodic/keyframe conflicts, interpolation/endpoint
  holds, cancellation/Escape, injected presentation errors and resource cleanup.
- Live update tests verify concurrent atomic parameter batches, nonblocking
  render-side snapshots, active-scene bounds and override persistence.
- Masked image and custom shader native queue tests verify uniform snapshots,
  blend/clip state, handle rejection, retained program/image/mask resources,
  unaligned inputs and cleanup. Tests do not synthesize procedural GPU pixels.
- Front-end demos exercised with the scripted presenter; pointer tests cover
  release, lost events, drag offsets, upload count and failure cleanup.
- Phone UI doubles cover navigation/report reopening, Diagnostic gating,
  persistence across reconstructed stores, matching timing/environment metadata,
  strict JSON, system-share cancellation, iPad anchors and temporary-file life.
- Main-thread idle collection policy tested for worker rejection, idle gating,
  setup/exit restoration and duplicate closure. This addresses a plausible cause
  of the UIKit cleanup warning; the real device warning is not proven resolved.
- Fresh Python 3.14 iOS device and ARM64 simulator wheels built. Briefcase project
  regenerated/updated; both Release app builds succeeded without developer signing
  (converted Python frameworks use ad-hoc signatures for this offline check).
- Both app bundles passed offline inspection: **88 compatible frameworks each**,
  correct device/simulator platform and minimum OS metadata, current demo/toolbox
  sources and shader assets, app privacy manifest, no static archives. OpenSSL
  `_ssl` and `_hashlib` privacy manifests/signatures passed separately.
- Fixed the upstream simulator Python.framework iOS-13 metadata mismatch with
  its arm64 iOS-14 binary by aligning copied framework metadata to this app's
  iOS-17 target before embedding/signing. Preparation remains idempotent.
- User confirmed the four-aperture image demo's visuals and mouse dragging in
  real Mac Octave on the 6016×3384, 60-Hz DSC display. This is a limited visual
  acceptance, not all-shader, all-host or timing validation.

## Explicit limits

GPU readback and built-in/masked-image/custom-shader Metal fixtures compile as
host programs but skip execution without a Metal device. Xcode's optional Metal
Toolchain is absent, so standalone MSL compilation also could not run here.
No new custom shader GPU pixels, physical frame timing, real UIKit sharing,
Main Thread Checker lifecycle, TestFlight or Apple submission is certified.
The simulator build succeeds; simulator launch is unavailable in this restricted
execution environment. An unsigned/ad-hoc local build is not an App Store archive.

Sampling advances once per submitted frame; submissions and GPU/software
presentation records do not prove physical light onset. Photodiode validation
remains necessary for emitted-light timing claims. Run phone timing from Home
Screen with Xcode disconnected, separately from Main Thread Checker checks.
The Octave binary uses installed Octave 11.3 libraries requiring macOS 26;
MATLAB/Python target macOS 14+. Rebuild for another Octave installation as needed.

See ROADMAP-0.8.0.md for the remaining physical-device acceptance matrix.
Video/audio are intentionally deferred. GitHub publication is separate from
Apple submission; no Apple upload is part of this release.

## October 10 review and release preparation

Re-reviewed the updated native timeline results/cancellation, Python input
concurrency, exact hard mask edges, Gabor orientation and tiled image packing.
Added serialized native input readers plus a binding regression that detects
simultaneous reader entry. Confirmed cancellation remains callable concurrently.
Removed MATLAB/Octave UpdateTimeline/CancelTimeline commands are intentional;
Python live controls remain supported. All shipped Mac/iOS modules are rebuilt
from these final sources. Package manifests/checksums are regenerated afterward.
GitHub wheel builds target 0.8.0; PyPI publication requires a separate explicit
manual workflow option, avoiding an unintended PyPI upload during GitHub release.
