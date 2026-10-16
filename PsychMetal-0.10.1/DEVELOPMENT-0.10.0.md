# PsychMetal 0.10.0 development — October 14, 2026

Historical development log: dated entries below retain the status at the time.
Current release-preparation status is in VALIDATION.md and RELEASE-0.10.0.md.
The published 0.9.0
folder and repository release workflows were not changed in this pass. Existing
movie/recording work and probes were preserved; no commit, push or upload was made.

## Completed in this pass

- Replaced the movie-audio tap's guessed 50 ms destruction delay with a
  lock-free reader acknowledgment. The callback announces its read before
  taking the pointer, and host-side detach waits for outstanding reads before
  allowing deletion. The callback does not wait, allocate or free.
- Bounded sound waiting for the first video frame to 256 blocks, instead of
  an indefinitely growing deque. Only discarded samples belonging to the
  movie count as lost; earlier samples are outside the recording.
- Bounded writer backpressure waits to 10 seconds and finalization to 30
  seconds. Failed/cancelled writers and errors in the other media thread
  terminate the readiness wait; the original error is retained. An already
  failed recording is cancelled instead of being sent through finalization.
- Added regressions for a callback suspended beyond the old delay, repeated
  detach/free during rendering, bounded pre-video sound, partial discarded
  blocks, and writer failure/stall/backpressure behavior.
- Updated the secure-input fixture to include and test the new interrupt path;
  it had stopped compiling after keys() gained throwIfInterrupted().
- Aligned active native/Python/MATLAB/Octave/phone version fields, Python
  packaging metadata, help/site copies and corresponding fixtures to 0.10.0.
  Bundle preflight reads VERSION instead of requiring a literal 0.9.0.
  The phone app now requires a fresh 0.10.0 wheel, avoiding accidental use of
  the earlier engine. No phone wheels or app were built in this pass.
- Rebuilt Octave, MATLAB and Python 3.15 Mac modules. Python/native version
  agreement checked as 0.10.0. Inherited physical validation is labeled as
  historical 0.9.0 evidence, not acceptance of this tree.

## Checks

- Native `make all PYTHON=/opt/homebrew/bin/python3.15` passed, no compiler
  warnings/errors. Build log: /tmp/psychmetal-010-build.log.
- Real macOS, iOS device and ARM64 simulator SDK type checks passed with
  -Wall -Wextra -Wpedantic.
- Audio core and host tests passed under AddressSanitizer/UndefinedBehaviorSanitizer
  and ThreadSanitizer, including the new tap ownership/backlog regressions.
- Python 3.15 and Octave frontend/mock-engine tests passed: **281/281 inventory
  checks over 104 commands**, **46/46 readback checks**, movie/record demos,
  menu/sharing recovery and synchronized version/help/privacy checks.
  These are scripted engine checks, not physical display or encoder tests.
- Actual Mac Python extension and MEX headless checks passed.
- Recorder readiness fixture passed for ready, failed and stalled writers,
  preserved cross-media failures and recoverable backpressure. It extracts
  the actual native readiness loop and shortens its timeout for the fixture.
- Full runner log: /tmp/psychmetal-010-verified-tests.log. The runner reached
  test-movie generation and then **failed** when AVAssetWriter returned
  "Cannot Encode" for the ProRes 4444 fixture. This is unresolved here;
  neither movie encoding/decoding nor GPU pixels are certified by this run.
  Metal pixel tests explicitly skipped because no Metal device is accessible.
  The final custom-shader pixel test after movie generation did not run.

## Continued implementation — October 14

- Recording shutdown now uses atomic shared ownership. GPU/writer completions
  retain the session; admitted frames increment pending before allocating, and
  Stop closes admission under the same mutex. Early failures release their
  reservation. A timeout cancels and joins audio safely, then late completions
  release their ownership instead of leaving a deliberately leaked recorder.
  Native admission/Stop and delayed-completion fixtures pass ASan/UBSan/TSan.
- Movie exports write a UUID-named temporary file beside the destination, and
  atomically rename it only after successful completion. Failed recording leaves
  a previous export intact. Actual file-commit tests pass without an encoder.
  Numbered test-movie generation uses the same transaction policy; an actual
  failed AVFoundation run preserved a sentinel destination and removed its temp.
- Audio interruptions end old playing/queued voices and microphone recording
  with Interrupted, preserve recorded samples, and disarm voice-key detection.
  Interruption generations prevent stale queued commands from restarting a
  stimulus while preserving requests issued after recovery. An unreported
  output callback gap also ends old voices. No audio callback waits/allocates.
- iOS notifications use a serial recovery queue with shared closed-state guards.
  Begin stops the unit; End reactivates/restarts only with shouldResume. Failed
  or denied resume leaves new playback disabled. Closing drains/invalidate
  recovery before disposing the unit. Interrupted stimuli are not replayed.
  Readiness/timing stays invalid after a route change until close/reopen.
- Real Foundation notification/dispatch tests cover begin/end, resume permission,
  failed activation/restart, and observer/close lifetime. Core/host tests cover
  interrupted voices and recording, callback gaps and post-recovery playback.
- Native Mac modules rebuilt again from these sources, Python 3.15 included.
  All requested checks in `tests/run_tests.py --skip-media-fixtures` passed:
  scripted inventory **281/281 across 104 commands**, readback **46/46**,
  frontend/demos/menu/report tests, SDK checks and sanitizers. Metal pixel
  execution and active-display enumeration skipped explicitly (no accessible
  GPU/display). Movie fixture generation skipped by the explicit option;
  the default runner still fails when an encoder fails. Log:
  /tmp/pm010-final-regressions.log. Build log: /tmp/pm010-final-build.log.
- Native test-movie diagnostics now print the underlying NSError chain. ProRes
  failed with AVFoundation -11800 / VideoToolbox -12903 (InvalidSession); a
  minimal H.264 attempt failed too. This does not establish a specific root cause.
- Fresh phone wheel build was attempted, but Xcode's Metal compiler component
  is unavailable. xcodebuild -downloadComponent MetalToolchain could not fetch
  the component catalog for this Xcode build. No stale 0.9.0 wheels were reused.
  Logs: /tmp/pm010-ios-wheels.log and /tmp/pm010-metal-toolchain.log.

## Remaining work from plan v3

1. Virtual recording, queued/native playback, frame-keyed audio and standalone
   offscreen recording are implemented; GPU/codec/device acceptance remains.
   Flip-loop/queued/native-playback virtual clocks and generated audio are implemented
   below. Live remains the low-level API default; microphone timing is not
   virtualized. See MOVIES.md for supported paths and clock domains.
2. The Metal compiler is restored. Investigate the AVFoundation fixture
   encoding failure. Then run actual numbered-frame recording/playback,
   held-frame timing, sound-track alignment and codec/size throughput tests.
3. Startup/display-capture measurements; texture-storage and direct float-texture
   optimizations with benchmarks. GPU-dependent work cannot be validated here.
   Mac device retargeting/restart after removal still requires close/reopen;
   the new automatic restart code is specific to permitted iOS interruptions.
4. Phone movie selection and Mac/iPhone/iPad hardware acceptance. Recording
   and explicit movie sharing are implemented; fresh app builds are below. Fresh device and simulator wheels were
   built on October 14 after installing the compiler; see the update below.
5. Final release notes, validation, manifest/checksums, workflow target and
   distributions once implementation and acceptance are finished. Inherited
   release inventory/checksums are not current. No commit/push/publication done.
6. Photodiode validation is deferred at Keith's request. It is not a prerequisite
   for continuing development; no physical optical-timing claim is made. Loopback
   and audiovisual measurement still need suitable hardware/clock alignment.

## Restoring the build environment

On the Mac's Terminal (not Octave), install/check Apple's component:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun -sdk macosx metal --version
xcrun -sdk iphoneos metal --version
xcrun -sdk iphonesimulator metal --version
```

If Xcode cannot fetch its catalog there either, use Xcode Settings > Components
and check that the installed Xcode build has a matching downloadable toolchain.
This is a build prerequisite, not a request for phone or photodiode testing.

The duplicate Makefile.new and existing flip_when probes were left intact.

## October 14: compiler restored and phone project refreshed

- Apple Metal compiler 32023.921 is installed. Both arm64 Python 3.14 iOS
  device and simulator wheels built successfully from the current sources.
- Shader compilation now uses the Metal driver to compile/link in one step
  and keeps its module cache in the build temporary directory.
- `PSYCHMETAL_METAL_COMPILER` can select an explicit compiler executable; the
  SDK sysroot and platform deployment target remain explicit. This worked
  around Xcode's simulator component lookup failure in this environment.
- Briefcase requirements, sources and icon resources were refreshed, then
  `phone/store/prepare_xcode.py` applied version/privacy settings.
- No physical-device validation, signing, upload or publication performed.

- Generic iPhone Xcode Debug build succeeded in `/tmp/pm010-xcode-device`
  with ad hoc extension signatures and no device provisioning. This confirms
  app packaging/building, not installation or physical-device behavior.

## Phone movie demos and error reporting

- Added Movie playback with a bundled 160x96, 30 fps, three-second H.264/AAC
  numbered sample. No Photos access or internet is needed. The shared Mac
  demo scales the clip to fit, rather than leaving it tiny on a phone.
- Added Record a stimulus, using the shared Python recording demo with H.264,
  half-resolution capture, generated sound and an app-local `movies/stimulus.mp4`
  destination. The demo replays the result; Photos selection and movie sharing
  are still future work. Labels respect the display safe area.
- Failed demos now open readable output even when Diagnostic mode is off,
  and write their exception to the Xcode console. Escape remains a normal stop.
- Sound recorder returned to the app menu on Keith's phone. The supplied log
  reaches display opening and includes missing hashlib algorithms, but contains
  no demo exception. The actual demo output is needed before claiming a fix.

- Updated iPhone Xcode build succeeded. Offline preflight passed all 88
  framework deployment checks, fresh demo/sample assets, Python `.fwork` links
  (including hashing modules), and both OpenSSL privacy manifests/signatures.
  Present files/links do not prove that those modules import on the device.
- Scripted phone menu tests passed for both video routes and error display with
  diagnostics disabled. Physical playback/encoding and the sound error remain
  unverified. No release or upload was made.

## Continued optimization and phone movie export

- Keith reports Sound recorder now opens and works without an error on the
  phone. This is user-observed demo behavior, not a physical audio timing test.
  The latest console no longer contains the earlier missing-hash messages.
- DrawMovieFrame now prepares one successor on the movie's serial queue while
  the caller draws/presents. PlayMovie uses that same path instead of a second
  prefetch implementation. Repeated draws retain their requested frame; seeks
  and future-frame errors remain exact. Pending work is bounded; asynchronous
  decode captures shared session ownership through close. Native extracted-path
  tests pass ASan/UBSan and TSan for repeats, seeks, EOF, future decode errors
  and close during a paused decode. Throughput is not yet hardware-measured.
- AVFoundation metadata waits are limited to 30 seconds. Decoded PCM is capped
  at 30 minutes or 256 MiB, whichever comes first. Leading silence is checked
  before allocating, and decoded audio sample buffers use scope-bound release
  so failed allocations/read errors do not leak the current sample.
- Share recorded movie is available outside diagnostics. The system sheet
  receives a temporary copy; cancellation preserves the app-local original,
  re-enables export, and prevents concurrent demos during sharing. Regression
  tests cover file snapshot independence and menu state recovery. Phone help
  and privacy documents describe the local movie and explicit export.
- No incorrect RunLoop execution with Common Modes was found in PsychMetal or
  the bundled Python UI code. Common-mode timer/source/display-link
  registrations are valid and were left intact. The warning's origin remains
  unconfirmed; a device stack at _CFRunLoopError_RunCalledWithInvalidMode would
  identify it. This has not been claimed as fixed.
- Mac Octave/MATLAB/Python modules and both iOS arm64 wheels rebuilt. Real SDK
  type checks pass for Mac, iPhone and simulator. H.264 AVFoundation encoding
  still fails here with -11800 / -12903, so actual codec/GPU acceptance remains
  pending; the software fixtures do not establish physical timing or pixels.
- Virtual recording clock, matching offline audio and standalone offscreen
  export remain unfinished implementation. Photos/movie selection, GPU
  performance benchmarks and final release materials also remain pending.

- Final continued-pass checks: `tests/run_tests.py --skip-media-fixtures`
  passed all available regressions (log `/tmp/pm010-continued-regressions.log`),
  including scripted inventory/readback, Mac/iOS SDK checks and sanitizers.
  Metadata late-completion ASan/UBSan test also passed and is now in the runner.
  GPU pixel/display checks skipped explicitly; media fixture generation was
  explicitly excluded and a separate H.264 attempt still failed.
- Updated Xcode iPhone build succeeded; bundle/privacy preflight passed all 88
  compatible frameworks and fresh source/assets. Generated device/simulator
  package binaries byte-match their newly rebuilt wheels. Source archive was
  rebuilt and verified against current native and shader-build sources.
  Logs: `/tmp/pm010-continued-build.log`, `/tmp/pm010-continued-ios.log`,
  `/tmp/pm010-continued-phone-build.log`. No commit, push, release or upload.

## Virtual clock and generated audio: first supported path

- Added opt-in `clock='virtual'` to Python/MATLAB/Octave StartMovieRecording;
  live remains the low-level default. Flip returns logical nominal refresh
  times, and GetSecs excludes time inside Flip. Caller work and real waits
  count normally; explicitly later targets preserve held frames. Stop/Close
  restores the physical clock. Recording reports identify `virtualClock`.
- Generated movie sound uses the SAME Mixer on a worker at logical sample
  times, observing newly issued Play/Stop/Modulate commands and retaining
  source samples. This includes stop/modulation after live voices retired.
  Start requires existing output voices to be stopped. Logs are bounded to
  65,536 entries / 256 MiB retained source PCM; overflow fails the export.
- Offline sound streams alongside video so writer interleaving/backpressure
  does not require holding the whole PCM movie in memory. Pre-roll is rendered
  and trimmed against the first video frame. This has been exercised with
  the actual sound-worker code and simulated slow appends, not a real encoder.
- Queued virtual playback (QueueFlip, PlayTimeline, PlayMovie) and startup
  confirmation during virtual recording are rejected explicitly. Ordinary
  DrawMovieFrame/drawing plus Flip work. Physical diagnostics, input and
  live audio events remain physical and must not be compared directly with
  logical timestamps. Standalone offscreen export is still unfinished.
- Recording demos default to virtual mode; a live option remains available.
  Documentation describes both clock domains and limitations. Native clock
  tests simulate encoder delays; generated PCM is identical across batching
  and retains exact click samples. Worker tests pass ASan/UBSan and TSan for
  slow appends, pre-roll trimming, contiguous stopping and sound alignment.

- Final clock refinements: sample grids align to the first video frame, including
  pre-roll at fractional refresh rates; actual worker fixtures check 59.94 Hz
  origins with slow appends. Video and generated PCM use the same rational
  recording period. Explicit CloseAudio logs StopAll to the export. Live device
  requests are mapped to physical time while the observer retains the original
  logical commands; host tests verify the two domains. Virtual Stop includes
  caller waits after the last Flip in the session end, rounded to a refresh.

- Final clock pass: native Mac modules and both iOS wheels rebuilt; current
  source archive includes both new headers and matches native sources. Full
  `tests/run_tests.py --skip-media-fixtures` passed all available checks,
  including scripted inventory 281/281 over 104 commands and readback 46/46.
  Clock/audio/worker checks pass ASan/UBSan/TSan; Mac/iOS/simulator SDK checks
  pass. GPU/display execution and codec fixture generation remain explicitly
  skipped/unvalidated here. Logs: `/tmp/pm010-clock-regressions.log`,
  `/tmp/pm010-clock-build.log`, `/tmp/pm010-clock-ios.log`.
- Refreshed Xcode phone project contains the new native device/simulator wheels.
  Generic iPhone build succeeded (ad hoc extension signatures, no provisioning);
  bundle and OpenSSL privacy preflight passed all 88 compatible frameworks,
  fresh sources/assets and manifests. No physical phone test, commit, push,
  publication or App Store upload in this pass. Queued virtual playback and
  standalone offscreen export remain implementation work, not test-only tasks.

## Virtual native playback and queue extension — October 14

- PlayTimeline and PlayMovie now own a scoped logical sequence clock while
  recording virtually. Each submitted refresh advances exactly one tick; scene
  sampling, movie decoding and presentation-report waits do not stretch export.
  Scope cleanup restores ordinary caller-time accounting after cancellation or
  errors. PlayMovie schedules its start and generated sound on the logical clock.
- QueueFlip now freezes logical time while rendering/admitting each frame. A
  stable physical anchor preserves queue ordering even when export takes longer
  than one refresh. Reversed logical targets are refused. QueueResults waits are
  excluded from logical duration; queue results remain physical diagnostics.
  Cancellation cannot remove frames already captured at queue submission.
- Standalone offscreen export and virtual frame-keyed audio remain unfinished.
  This source update needs fresh phone wheels before device testing.

Validation of this extension: Mac Octave/MATLAB/Python modules rebuilt with no
compiler warnings; real Mac/device/simulator SDK checks passed. The full software
runner with `--skip-media-fixtures` passed, including frontend inventory/readback,
virtual queued/timeline/movie playback, extracted native queue wrappers and
ASan/UBSan/TSan clock tests. Delays up to three seconds per submitted frame
preserve the intended cadence. Logs: /tmp/pm010-sequence-build.log,
/tmp/pm010-sequence-sdk.log and /tmp/pm010-sequence-regressions.log. GPU pixel
execution and actual codec/device validation remain explicitly unverified. No
phone wheels/app, source archive, release assets, commits or uploads were made
for this extension; previously generated packages predate these source changes.

## Virtual frame-keyed generated sound — October 14

QueueFlip tokens retain a bounded logical timestamp history within the current
recording, independently of the physical presentation records. Play resolves its
export request using that logical time, while the device and output event reports
use the physical projection. Old-session and overwritten tokens are rejected.
The offline command log now accepts ordered insertion of requests into intervals
not yet rendered. The mixer worker claims each PCM interval under the same mutex
as command admission, closing a race where a retroactive request could otherwise
arrive while the sink was writing and be silently played late. Requests for PCM
already claimed fail the export; callers should schedule frame-keyed Play directly
after QueueFlip, before submitting later frames. No device callback takes this lock.

## Standalone export canvas — October 14

Added open_export(width,height,refresh_hz) in Python and the OpenWindow exportSize
option in MATLAB/Octave. Native OpenExport initializes the common Metal resources
without AppKit/UIKit window creation, display capture/enumeration, display links
or drawables. Flip renders through encodeFrame and the same transactional movie
writer; it waits for bounded GPU completion and never claims presentation.
The session requires virtual recording. CPU work does not advance export time;
WaitSecs advances the logical timeline without sleeping. Native playback scopes
nest within that clock. Queued display presentation is refused. On iOS a separate
foreground observer stops submissions on resign-active and restores the previous
idle-timer setting on close, without replacing the app's window. Added Python and
MATLAB/Octave standalone drifting-Gabor demos and OFFSCREEN-EXPORT.md.

The phone menu now includes Export a stimulus and routes it to writable app-local
storage, sharing the existing completed-movie export control. Help/privacy pages
and the local website copies describe it. Phone demo parity checks and app path
fixtures include the shared export_demo.py; no duplicate phone renderer was added.
Standalone Python context cleanup leaves cursor visibility untouched.

## Verification — October 15, 2026

Mac Octave/MATLAB/Python modules rebuilt without compiler warnings. Real Mac,
iPhone and simulator SDK checks pass. All available software regressions pass
with `--skip-media-fixtures`, including 281/281 MATLAB/Octave inventory checks
over 104 commands, 46/46 readback checks, extended Python command coverage,
standalone demos on both frontends, phone catalogue/app-local export routing,
exact frame-keyed PCM, sorted audio admission and the in-flight PCM claim race,
ASan/UBSan/TSan clock/audio/export fixtures, bounded GPU waits and failed-session
refusal. The final encoding-exception case also passed the targeted export fixture
and SDK checks after the suite had entered its frontend stage. Logs:
/tmp/pm010-export-build.log, /tmp/pm010-export-sdk.log,
/tmp/pm010-export-regressions.log. Metal pixel execution is explicitly skipped
without an accessible GPU; actual codec/device acceptance remains pending.

Fresh iOS device/simulator wheels were built, the Briefcase project refreshed,
and the generic iPhone app rebuilt successfully. Bundle preflight passes with
88 compatible frameworks/current source and assets; embedded OpenSSL privacy
manifests/signatures pass. Generated native packages byte-match the current
wheels, and the refreshed source archive matches the final export/audio sources
and OFFSCREEN-EXPORT.md. Logs: /tmp/pm010-export-ios.log,
/tmp/pm010-export-phone-update.log, /tmp/pm010-export-phone-build.log and
/tmp/pm010-export-sdist.log. No commit, push, GitHub release or Apple upload.

## Phone export completion feedback — October 15

The supplied device log showed the export canvas opening without an export
exception, but the UI previously returned silently to the menu. Export now tags
its completion result and logs saved-frame/duration information. The phone
checks that the reported app-local file exists, is nonempty and has valid
metadata before opening a native Movie ready page, independent of diagnostics.
It offers Play exported movie (the generated clip, not the bundled sample),
Share movie and Back to demos. Sharing cancellation restores both share buttons
and retains the movie. Missing/empty/wrong-path exports open the existing error
page automatically. The export introduction uses Create movie and explains that
no stimulus is presented during creation. Help/local website copy are synchronized.

Frontend/mock regressions pass, including new completion, preview path, sharing
and error cases; the final intro/label changes also pass the targeted UI run.
Briefcase sources were refreshed and the generic iPhone app rebuilt successfully.
Bundle/privacy preflight passes with current source and 88 compatible frameworks.
Logs: /tmp/pm010-export-feedback-tests.log, /tmp/pm010-export-feedback-ui.log,
/tmp/pm010-export-feedback-update.log and /tmp/pm010-export-feedback-build.log.
No native engine/wheel change was needed. Actual phone confirmation remains
pending; no commit, push or upload was made.

## Recording A/V tail timeout — October 15

The physical-phone log reported a writer readiness timeout at Stop in Record a
stimulus; standalone silent export completed 180 frames / 3 s. Found a producer
EOF ordering bug: generated audio had no final horizon until the video append
queue drained, and both inputs were marked finished only after the audio thread
joined. AVAssetWriter interleaving can withhold either input's readiness until
the other producer signals EOF (AVAssetWriterInput markAsFinished SDK contract).

Virtual frame admissions now track the settled first aim and final tick under
the recorder mutex. Stop publishes the exact audio tail and closes admissions
before draining pending video. The audio producer signals its own EOF on exit;
the last video completion signals video EOF. A completion marker keeps Stop
waiting until that EOF call returns. Per-input atomic guards prevent duplicate
EOFs; native EOF exceptions become a recorder error instead of aborting the app.
Readiness timeouts identify audio versus video. Failed exports report that any
previous destination was preserved, rather than calling the destination file
incomplete. No codec, source image, frame rate or audio samples were discarded
to work around the stall. The early exact tail applies to virtual recording;
live recording retains its existing tail calculation.

Added tests/test_recording_interleave.py using the actual admission, readiness,
release, EOF and offline sound-worker code with Foundation-controlled inputs.
Both directions of interleaving stalls complete without timeout, including
delayed video, exact PCM onset/tail, idempotent EOF and exception/error handling,
under ASan/UBSan/TSan. Admission/Stop lifetime and offline PCM tests also pass.
Physical iPhone codec confirmation of the change remains pending.

Recording-tail verification: Mac modules and both iOS wheels rebuilt; real
Mac/iOS/simulator SDK checks pass without warnings. All available software
regressions with --skip-media-fixtures pass. The interleaving regression also
passes with delayed EOF delivery, proving Stop waits through the completion
marker. The refreshed generic iPhone app builds; bundle/privacy checks pass
with current sources and 88 compatible frameworks. Generated native packages
match the new wheels and the source archive matches the final recorder/clock
headers and MOVIES.md. Logs: /tmp/pm010-eof-build.log, /tmp/pm010-eof-sdk.log,
/tmp/pm010-eof-regressions.log, /tmp/pm010-eof-ios.log,
/tmp/pm010-eof-phone-update.log, /tmp/pm010-eof-phone-build.log and
/tmp/pm010-eof-sdist.log. User reports standalone phone export/replay works;
its console confirms 180 frames / 3 s / 122294 bytes. The A/V recording fix
still needs confirmation on the phone. No commit, push or upload.

### Mid-stream recording stall follow-up

The phone still freezes near its first click; the new log identifies a video
readiness timeout, so the preceding EOF repair did not resolve this case. Both
writer inputs were incorrectly classified as independent offline sources whenever
the timestamp clock was virtual. Generated PCM stops at the admitted video
horizon; ideal-interleaving throttling of video can therefore stop its own audio
producer. Both inputs now use push/real-time input mode, retaining readiness
checks, bounded frame admission, logical timestamps and exact PCM. The standalone
export canvas uses the same policy because it has the same producer dependency.
A controlled readiness test includes an old-mode negative control and 360
new-mode admissions, alongside existing EOF/tail tests. This models the dependency;
it is not evidence of an actual hardware encoder run. Phone confirmation pending.

Push-source verification: Mac modules rebuilt; actual Mac, iOS and simulator SDK
checks pass. Full available regressions pass with --skip-media-fixtures; actual
codec execution and GPU pixels remain explicitly unvalidated here. Device and
simulator wheels rebuilt and byte-match generated packages. Refreshed generic
iPhone app builds, bundle check passes (88 frameworks) and OpenSSL manifests/
signatures pass. Source archive matches the current recorder and MOVIES.md.
Logs: /tmp/pm010-push-{build,sdk,regressions,ios,phone-update,phone-build,sdist}.log.
No commit, push, release or upload. The phone test is still required.

### Recording-demo replay startup
User confirms recording now completes, but A/V looks out of sync in the saved
movie's in-app replay. The Python and MATLAB/Octave demo scheduled audio before
first-frame decoding. Replay now decodes/queues frame zero before choosing the
shared start, with at least 100 ms lead. Remaining frames retain the original
variable timestamps (including deliberate holds); constant-rate PlayMovie would
shorten those holds. No recorded samples or frame times are changed. A controlled
cold-decoder test delays first decode by up to 2 s and checks shared A/V onset,
held timestamps and silent replay at 60/120/119.98 Hz. Physical confirmation is
still pending; this repair addresses startup, not arbitrary later decoder stalls.

Replay verification: the cold-decoder check passes, including refresh-grid
start alignment. Python and Octave front-end checks pass, and the final Python
helper separately passes against the built mock frontend. Updated generic
iPhone app builds and contains the final replay source; bundle/privacy checks
pass (88 frameworks). Refreshed the source distribution. Logs:
/tmp/pm010-replay-{frontends,current-demo,phone-update,phone-build,sdist}.log.
No native recorder change in this follow-up; existing wheels retained.
No commit, push or upload. Physical replay synchronization remains pending.

### Replay throughput follow-up
The user still sees A/V mismatch and visibly slower replay. Startup preparation
alone was insufficient. The demo's mandatory all-frames playback accumulates
video delay if decoding/drawing misses deadlines, while audio runs at real speed.
The Python and MATLAB/Octave recording-demo previews now select the latest due
frame whenever they fall behind; original file timestamps still govern playback
and holds remain. This changes preview policy only, not recorder samples or the
core PlayMovie API's all-frames semantics. Reports expose skipped preview frames,
elapsed time to the final frame, and maximum delay. Slow-decoder regression uses
25/60 ms frame costs at 60/120 Hz and a half-second timestamp gap; the previous
policy drifts by >1 s, whereas the preview remains within one decode plus refresh
quantization. This cannot eliminate individual decoder stalls or physically
validate audio/display onset. Phone replay confirmation remains pending.

Preview cadence verification: slow-decoder tests pass with shared start and
original held timestamps. Preview selects the picture due after the preceding
measured decode/draw cost, preparing ahead rather than lagging by that cost.
Python/Octave front-end checks pass. Generic iPhone build and bundle/privacy
checks pass; the built app byte-matches the final replay source. Native wheels
are unchanged because this fix is in demos. Source distribution refreshed.
Logs: /tmp/pm010-preview-{frontends,phone-update,phone-build,sdist}.log.
Physical replay sync remains unvalidated; no commit, push, release or upload.

## Authorized wishlist completion — October 15
Keith authorized all remaining implementation items except measurement probes.
Tracking: (1) private/static and direct float32 textures; (2) bounded movie ring
and whole-movie preload; (3) all-intra conversion helper and keyframe metadata;
(4) playback A/V end offset reporting; (5) event-driven startup and explicit
capture comparison; (6) Mac audio retarget/restart; (7) shared interface tests,
documentation and fresh builds. Hardware-only benchmark/acceptance results must
remain pending until actually measured. No release authorized in this pass.

### Remaining-wishlist implementation details

- Static MakeTexture uses staged private GPU storage; full updates switch to
  reusable shared snapshots. Private partial uploads preserve borders/pitch.
  Failed/timed-out upload command buffers invalidate the session.
- Float32 in upload layout is validated and uploaded directly to R32/RGBA32
  where MTLDevice supports32BitFloatFiltering. Unsupported GPUs keep the
  half-float path. Strided/RGB/clamped data packs as Float32; partial floating
  writes retain the existing precision and support either single/double input.
  Null native image views are rejected before packing.
- Movie decode caches a bounded eight-frame lookahead (256 MiB pixel budget),
  with PrepareMovie for configurable lookahead or explicit whole-movie preload.
  Shared ownership retains requested/cached frames during close. The decoder
  refuses to substitute a later frame if an expected frame is missing.
- OpenMovie includes maximum keyframe spacing; TranscodeMovie is a standalone
  AVFoundation all-intra converter with original timestamps/orientation and
  transactional output. It uses 8-bit BGRA and stereo audio, not an HDR or
  multichannel preservation path.
- PlayMovie reports internal audio/display start/end offsets and their change
  without consuming AudioResults. Missing evidence returns NaN. These are not
  physical timing measurements and include presentation misses/track padding.
- AppKit startup pumps events in short slices and waits for consecutive actual
  confirmations instead of sleeping one second. Confirmation remains bounded
  to two seconds / 120 attempts; default display capture is retained.
  A capture opt-out and actual-capture diagnostic support performance comparison.
- Mac device recovery preserves the Session, loaded sounds, client sample rates
  and saved recording samples, interrupts old voices, retries failures after a
  cooldown and falls back from unavailable explicit endpoints. Repeated route
  changes on a fallback check the originally requested endpoint, preventing a
  later retry from selecting a still-absent device. Timing remains invalid.
- Added performance_audit.py; no photodiode/loopback/AV probes were added/changed.
  Native fixtures cover upload failures/regions, direct float packing, movie
  preload/cache/seek lifetimes, non-draining audio timing, and Mac recovery.

The real standalone converter's attempted H.264/AAC conversion cannot encode
audio in this environment. Its failure preserved a sentinel destination and
removed the UUID temporary file. This verifies cleanup, not successful encoding.
Log: /tmp/pm010-wishlist-transcode.log. Hardware conversion acceptance remains.

Final movie review caught an existing selected-range bug: first/count playback
used the whole soundtrack from its beginning. Both wrappers now crop the audio
source interval and duration, include range in the cache key, bound each movie
to one cached handle, and clear movie caches at CloseAudio. A binding regression
checks the selected waveform sample and exact sample count and audio reopen.

### Final wishlist-pass verification — October 15

The remaining software items in WISHLIST-0.10.0.md are implemented. No measurement
probes were added or edited. Display capture remains the default pending actual
comparison/tear measurements; no unmeasured performance conclusion is asserted.
Final review also fixes movie-report collection after a terminal missing frame,
preload reconfiguration retaining two complete caches, incompatible old input/
output rates on a shared fallback device, and recovery restarting during Close.
Targeted tests cover each guard.

- Final full available runner with --skip-media-fixtures passes: scripted
  inventory 286/286 across 106 commands and readback 46/46, Python/Octave front
  ends, all demos, SDK checks, native fixtures and sanitizers. GPU pixel checks
  explicitly skip; movie encoder fixtures are explicitly omitted.
- Actual Mac, iOS device and simulator SDK type checks are clean. Portable
  declaration/stub checks for all three paths are also clean.
- Mac Octave, MATLAB and Python 3.15 modules rebuilt. Both Python 3.14 iOS
  device/simulator wheels rebuilt. Generated native/Python packages byte-match
  the final wheels; the source archive matches current native sources, wrappers
  and included documentation.
- Refreshed generic iPhone Debug app builds. Bundle/privacy checks pass with
  88 compatible frameworks, current app sources/assets, microphone usage text
  and signed OpenSSL privacy manifests. This is not an Apple upload or physical
  device acceptance result.
- Real standalone conversion was attempted; this environment refuses audio
  encoding. The prior destination and temporary-file cleanup were verified on
  that failure. Successful codec conversion, pixels and physical A/V timing are
  not certified. The earlier user-observed replay pass predates this engine
  refresh and does not replace a fresh phone check.

Logs: /tmp/pm010-wishlist-{build,sdk,stubs,regressions,ios,phone-update,
phone-build,transcode,sdist}.log. No commit, push, release or App Store upload.
Next hardware work: 50 Mac opens, texture/capture benchmark and tear comparison,
Mac device recovery, codec/preload acceptance and the refreshed phone demos.
Photodiode/loopback/AV probes remain excluded as requested.

## Efficiency audit — October 15

See AUDIT-0.10.0.md for the six targeted cleanup changes, verification and
remaining profiling candidates. Mac modules and both phone wheels are refreshed; the generic iPhone Xcode
build succeeded and bundle/privacy preflight passed. Makefile.new is preserved but ignored.
Release staging still needs a fresh version-specific manifest/checksum pass.

## Phone demo launch pages — October 15

Moved the primary demo launch action into a fixed top section with a 64-point
filled teal button and white label. Demo settings appear beside it, with live
values; the instructions scroll below. Export retains Create movie. Updated
help/catalogue wording and navigation checks, including launch after sharing
and Hidden ring option forwarding. No native engine changes in this UI pass.

UI navigation/option-forwarding checks passed against the scripted engine. The
generic iPhone build succeeded and bundle preflight passed with fresh app
source/help. Physical appearance and touch interaction still need a phone check.

### Phone feedback: Hidden ring controls

Changed every launch button to full width; settings stack beneath it rather
than competing for horizontal space. Hidden ring sliders now use the page width,
show minimum/maximum endpoints and live values, and explicitly colour both iOS
track segments so the unfilled portion remains visible on the light background.

## Release preparation — October 15

Prepared clean 0.10.0 release notes/changelog/landing page/citation and updated
CI package targets. Manifest selection now explicitly excludes local probes;
generated builds, caches and logs remain excluded. Regenerated manifests and
checksums and staged a verified ZIP, Python 3.14 Mac wheel/source archive and
iOS wheels. Hardware limits are explicit in VALIDATION.md. No commit, tag, push,
GitHub release, PyPI publication or Apple upload has been performed.
