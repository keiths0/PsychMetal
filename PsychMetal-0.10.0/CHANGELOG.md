# Changelog

## 0.10.0 — development

- Arcs, as Screen's: `FillArc` (a wedge), `FrameArc` (a band of the edge, pen
  width pixels wide, no radii) and `DrawArc` (one pixel), in MATLAB, Octave and
  Python (`fill_arc`, `frame_arc`, `draw_arc`). Angles in degrees, 0 at the top,
  clockwise; a negative sweep runs the other way; a 4xN rect with one angle or one
  per rect. Drawn on the GPU as shape kind 8, analytically and antialiased, in
  the same pass as ovals. `tests/test_arc_metal.mm` checks the pixels against the
  geometry in double precision, and a whole turn against the oval. The shapes
  demo draws its arcs with them.
- A display with a variable refresh rate (ProMotion) no longer opens at a
  provisional 60 Hz: Open takes the panel's maximum from AppKit
  (`NSScreen.maximumFramesPerSecond`) and warns that timing work wants a fixed
  rate. Not yet run on a ProMotion Mac.
- Phone app: Noise through a mask is no longer on the menu; the Mac keeps it as
  an example of the procedural stimulus calls.
- Movies (MOVIES.md), in MATLAB, Octave and Python: `OpenMovie`,
  `MovieFrameTimes`, `DrawMovieFrame`, `PlayMovie`, `RefreshesPerFrame`,
  `CloseMovie` (`open_movie`, ...). Any file AVFoundation reads (.mov, .mp4,
  .m4v; H.264, HEVC, ProRes, ...), decoded by the system with `AVAssetReader`,
  every frame in order, handed to Metal through `CVMetalTextureCache` without a
  copy. `DrawMovieFrame` draws one frame as `DrawTexture` draws a texture.
  `PlayMovie` shows every frame for the same whole number of refreshes (the
  nearest to refresh rate over frame rate, a half rounded up), never drops,
  repeats or alters one, and reports what the display reported. The movie's
  sound plays through PsychMetal's audio from the first frame's refresh: only at
  the movie's own rate by default, or resampled or time-stretched (AVFoundation's
  spectral algorithm) to follow frames shown at another rate. A track meant to be
  shown turned (a phone's portrait video) is drawn turned. `make test` writes
  numbered test movies (`tests/make_test_movie.mm`, AVAssetWriter) in five forms
  and reads each back; the inventory tests check frame numbers in the pixels
  drawn. New demo: `PsychMetalMovieDemo`, `python/movie_demo.py` (Mac only for
  now). Decode speed for 4K and 6K movies is not yet measured.

## 0.9.0 — 2026-10-12

- Final review (October 12): float textures now support unaligned buffers safely;
  voice-key triggers retain their recording index when that input buffer ends
  the recording. Sound loading enforces normalized -1..1 samples; amplification
  belongs in playback gain. WhiteNoise rejects negative amplitudes and returns
  silence for zero amplitude without constructing an invalid distribution.
  Phone sound controls recover after lost touch releases, and recorder buttons
  stop showing Recording when memory fills; obsolete recording-end events do
  not replace a newer recording's state. Undefined-behavior sanitizer findings
  fail the regression runner. Mac CI uses macOS 15 and ensures Metal is installed.
  See PRERELEASE-REVIEW.md for checks, physical acceptance and remaining release checks.

- Shapes demo (`PsychMetalShapesDemo`, `python/shapes_demo.py`): twelve
  labelled panels, one per kind of shape (rectangles, ovals and polygons filled
  and framed, lines, dots, arcs and wedges from polylines and polygons, text, a
  Gabor patch, translucent blending), several moving. It replaces the single
  red rectangle in the phone app; the minimal demo stays on the Mac as the
  smallest program to start from.
- Hidden ring: one demo in MATLAB, Octave, Python and the phone
  (`PsychMetalHiddenRingDemo(seconds, speed, cellSize)`,
  `python/hidden_ring_demo.py [seconds] --speed N --cell N`), with the
  background's drift in pixels per frame and the noise cell size as settings,
  both 1 by default. On the phone it replaces four menu entries, and its start
  page offers both settings.
- From the code review (../docs/12_code_review_0.9.0_v4.md): Apple's own
  interfaces in place of workarounds, more on the GPU, less code. Changes that
  break existing programs come first.
  - **Removed:** `PrepareFlip`/`PresentNow` (`prepare_flip`/`present_now`),
    `SetDisplaySync` (`set_display_sync`), `PrefetchDrawable`
    (`prefetch_drawable`; prefetch itself stays, always on: see below), and the
    OpenWindow options `waitForConfirm`,
    `displaySync` and `captureDisplay` (`wait_for_confirm`, `display_sync`,
    `capture_display`). Each is now an unknown command or option. The display
    is still captured, always, as it was by default. They were
    research instruments; the probes that used them are now in `probes/` at the
    repository root, outside the package, and run with 0.8.1.
  - **Prefetch is kept, and is no longer an option.** With direct presentation
    and three drawables, Flip takes the next frame's drawable as it ends, so the
    wait for one falls before the program reads its input. Taking it late
    instead, which was tried, measured 2.96 refreshes mouse to photons on a Mac
    against 1.96 (the display link: 2.82). The engine now turns it on itself
    after startup, so the front ends no longer do.
  - **Frame history has 14 columns:** `presentCallMs` and `prefetchMs` are gone,
    so the columns after them move left by one and two.
  - **Diagnostic returns 25 fields** (listed in PsychMetal.m's help and the
    Python docstring) instead of about 70. Window, view, layer and screen
    frames, activation policies, the mach timebase and key-scan timing are gone.
  - **Polygons are drawn on the GPU:** one quad per polygon, filled by the
    even-odd rule and antialiased by distance in the fragment shader, with the
    points in a buffer. A polygon that rotates or deforms costs nothing extra on
    the CPU. Outlines now have round outer corners (CoreGraphics drew mitred ones).
  - **WhiteNoise** is generated in the shared core (64-bit Mersenne Twister), so a
    seed gives the same samples in MATLAB, Octave and Python, and different
    samples from 0.8.x.
  - **Keyboard queue (Mac):** key events come from `IOHIDManager` with their own
    timestamps when Input Monitoring is granted; otherwise the 2 ms poll. One
    source at a time, so the 20 ms reconciliation window is gone.
    `secureInputPID` is now 0 or -1 (from `IsSecureEventInputEnabled`); the
    owning process is no longer looked up in an undocumented session key.
  - Mouse event times come from `NSEvent`'s `timestamp` instead of guessing the
    units of `CGEventGetTimestamp`. Modifier bits use Apple's
    `NX_DEVICE…KEYMASK` names.
  - Kept, after trying to replace them: Open still waits a fixed second for
    AppKit, captures the display, and activates with the deprecated
    `activateIgnoringOtherApps:`. Waiting instead for AppKit to report the window
    visible never ended for a program started from Terminal (the window was up,
    the app inactive, occlusion "not visible"), and with that wait the first
    directly presented frame never reported, so Open failed. Bisected on a Mac
    with macOS 26: the fixed wait confirmed, the new one did not, with either
    shader library. Why the new wait stopped the first frame is not known.
  - Precise waits run with a time-constraint thread policy and spin only a
    margin learned from recent wake-ups (0.5 to 20 ms) instead of at least 4 ms.
    Measured on a Mac against 0.8.1 (probes/wait_accuracy_v1.py, 900 waits of
    1-20 ms each way): CPU while waiting fell from 39 % to 5 %; returns stayed
    within microseconds (99th percentile 10.9 µs late idle, 5.9 µs with 23 cores
    busy, against 7.5 and 3.7; worst 87 µs against 30).
  - Two polls became waits on a signal: opening audio at a new sample rate
    waits for the device's notice that its rate changed (not a 10 ms poll), and
    starting the input thread waits for it to publish its run loop.
  - **The built-in shaders are compiled at build time** (`xcrun metal`, then
    `metallib`) and embedded, so opening a window no longer compiles source.
    Building now needs the Metal compiler: with Xcode 26 or later,
    `xcodebuild -downloadComponent MetalToolchain`. Custom shaders still compile
    when made, as they must.
  - One implementation, in `PsychMetalShared.cpp`, of what MATLAB and Python each
    did their own way: text wrapping and layout, the key-name table, stimulus
    and mask parameters from named options, and Tone, Click and WhiteNoise.
    Gabor and noise math is shared by the shape and stimulus shaders.
  - `LinkInfo` is labelled best effort: it reads IORegistry entries that are not
    a documented interface, and says unknown when they are absent.
  - Earlier releases' entries (0.1 to 0.6) moved out of this file.

- After the audit: on a Mac, a change of the device's sample rate or buffer size
  that this session did not make invalidates timing and warns, and closing
  restores the rate and buffer size opening changed. Opening at a new rate waits
  for the device to switch, which it does after the request returns; before,
  every new rate failed and the device switched anyway and stayed switched. A
  rate the device does not offer is refused with the rates it does. Device
  notices arrive on PsychMetal's own queue, with copies of what they compare,
  so none can reach audio state that closing has freed.
- Python showed a route or interruption warning only the first time from a
  given place in a program, so a second one (headphones unplugged, then Siri)
  went unreported. Every one now shows, as in MATLAB and Octave.
- A route change or interruption with no audio call after it (a steady tone,
  then Quit) was never reported; closing audio now reports it. Found with Siri
  on an iPhone. Voices retire on their own
  ring, so lost events never keep a sound in memory (at most 2048 voices
  outstanding). Ids are process-wide, so handles kept across close and reopen
  never name new sounds or voices. Interruption recovery and measured timing are
  stated limits (AUDIT-0.9.0.md).
- The output stopping for a while is detected from the callbacks themselves: a
  buffer that starts more than 50 ms after the previous one ended warns and
  clears `timed`, as a reported interruption does, whether or not the system
  posted a notice.
- Audit fixes: recording restarts acknowledge the reset before sample copying;
  Python shutdown serializes with audio; unaligned sound arrays load safely and
  float overflow is rejected. Callback command draining is bounded, audio event
  results merge by timestamp, converter and notification lifetimes are protected,
  and detected route changes invalidate timing status. The live spectrogram
  reuses its window and frequency grid. See AUDIT-0.9.0.md for remaining findings
  and the hardware validation still required.

- Audio (AUDIO.md): sounds that start and stop on the sample nearest a GetSecs
  time or a queued frame's projected presentation; recording on exact samples;
  a one-shot voice key; an input monitor; one event stream with every time.
  Core Audio on the Mac (HAL output and input units) and the audio session and
  RemoteIO on iOS; Python, MATLAB and Octave commands; Bluetooth and AirPlay
  refused for timed playback unless asked for. Audio has its own lock, so it
  runs beside drawing on another thread. Design: ../docs/11_audio_design_v3.md.
- PsychMetalAudio.h (real-time core: rings, mixer, recorder, voice key, input
  monitor) and PsychMetalAudioHost.h (sessions, sounds, events) are plain C++.
  The scripted engine drives them with a simulated 48 kHz loopback device, so the
  front-end tests run the real host and core code, sample for sample.
- Amplitude modulation of any playing sound (`modulate`, `Modulate`): the
  samples are multiplied by 1 - depth * (1 - cos(2 pi hz t + phase)) / 2, t
  each sample's GetSecs time, so a modulated sound and a frame drawn for its
  presentation time follow the same function of one clock. Changes take effect
  on the sample nearest their time, at once or timed, and the phase is computed
  per sample from that sample's time, so it never drifts.
- The input monitor refused any read that a new buffer arrived during, so a
  read slower than one buffer never succeeded (the core test hung under the
  thread sanitizer on a Mac). It now refuses only reads whose samples were
  overwritten.
- Demos: python/audio_demo.py and PsychMetalAudioDemo.m, a live spectrogram of
  the microphone with hold-to-record, play and stop buttons;
  python/modulation_match_demo.py and PsychMetalModulationMatchDemo.m, phase
  and frequency matching between a blob flickering from grey to white and an
  amplitude-modulated tone, each seen or heard, with a dial for phase, a log
  slider for frequency and the error after each match. Seen frequencies are the
  measured refresh rate over an even number of frames, so every cycle shows the
  same frames with its peak and trough among them.
- iPhone app: a Sound and time section with both sound demos, laid out inside
  the screen's safe area, driven by finger, and accepting Bluetooth or AirPlay
  output with an on-screen note that its delay is not measured. The microphone
  usage text, help page, privacy policy (in the app and on the support site) and
  review notes describe the recorder's microphone use; the bundle check fails a
  build without the usage text.
- A refused microphone is its own error, PsychMetal:Microphone; the recorder
  demos explain it and end instead of failing.
- iOS: route-change notices that only report the session's own category change
  no longer raise the route warning; interruptions warn when they begin.
- iOS: with input open, output that lands on the receiver (the earpiece) is moved
  to the speaker, at open and again when headphones are unplugged; headphones
  keep it. Confirmed on an iPhone: before this, recorder playback went to the
  earpiece. The recorder demos show the recording's
  peak, raise a quiet recording to half scale for playback (at most +30 dB) and
  name the output it plays through.
- Not yet measured on hardware: Core Audio latencies and onsets, iOS sessions.

## 0.8.1 — 2026-10-10

- Use explicit UIKit setters to hide and disconnect the temporary share window,
  and finish native modal dismissal before removing its root controller.
  Full-width sharing and cancellation recovery were confirmed on a physical
  iPhone, including the final release smoke test.

- Recover the menu window when a system share sheet closes without calling its
  activity completion handler. Observe native presentation state after opening,
  cover popover dismissal as well as adaptive dismissal, and ignore stale timers
  from earlier shares. Keep exports alive while any share UI is still presented.

- Hide optional diagnostic tasks and all report tools while Diagnostic mode is
  off, including restored reports on first launch. Saved reports remain intact.

- Fix report sharing on iPhone immediately after launch: present from a dedicated
  scene-connected UIKit window, and restore the menu window after dismissal.
- Correct the Rubicon `objc_id` import and native dismissal getter.
- Recover Share reports and Start demonstration after cancellation or native
  dismissal observation failures; retain exported files through dismissal.
- Display full, scrollable sharing errors and retain reports for retry.
- Correct the About page version and synchronize the app/support help pages.
- Synchronize the generated Xcode app version during preparation, including
  projects copied from an earlier release.
- Add regression checks for sharing lifecycle, window cleanup, version labels,
  readable errors and starting a demonstration after sharing.

- Detect an attached debugger (Xcode, lldb). Opening a window then warns
  `PsychMetal:Debugger`, the environment report has `debuggerAttached`, and the
  phone's Frame timing report says its timings are not representative. A device
  log showed why: with Xcode attached, drawing is delayed 7–13 ms about once a
  second, on a clock unrelated to the display, missing one 120 Hz refresh each
  time; GPU time and garbage collection were unchanged. Unplugged, there were none.

Review fixes:

- Share sheet: if UIKit never calls the dismissal completion, the menu and Share
  reports return after one second instead of staying disabled until relaunch.
  The share-geometry and teardown logging used for device debugging is removed;
  only failures are logged. The app's version label comes from the package.
  Paths in shared output (tracebacks and warnings) are relative to the app,
  without the container path that identifies the install.
- Python: a refused `close()` (another thread holds the engine) leaves the
  session and the module's record of it open. `stop()` now also ends
  `wait_secs` (at once, mid-wait; Ctrl-C too), `kb_queue_check`,
  `kb_queue_get_events`, `queue_results` and `wait_to_draw`. `close_shader`
  accepts a one-element array. `draw_masked_texture` takes `None` for angle and
  filter. `draw_stimulus` rejects an unknown mask texture, as the other draws do.
  `recent_frames` raises `PsychMetalError`, like every other call.
- Custom shaders: the engine's wrapper is compiled before the user's source, so
  a user `#define` cannot change its clamping or discard. Compile errors keep
  only the user's messages, with the user's line numbers, untruncated (they
  were cut at 1,024 bytes). Source without `psychmetal_main`, or with another
  signature, fails at CreateShader with a message saying so.
- MATLAB/Octave parity: `DrawStimulus` takes `w, recipe, rect, mask, coverage,
  overrides`, the order of Python's `draw_stimulus` (overrides moved from fifth
  to sixth). `Resolution` refuses a refresh rate without a size, as Python
  does. New `RecentFrames` and `ExportEnvironment`; `Environment` takes an
  optional window and returns the same fields as Python's report, not the
  wrapper's internal state.
- `WaitSecs`/`wait_secs`: the spin margin shrinks back to 4 ms after punctual
  wake-ups; one late wake-up no longer leaves up to 20 ms of busy-waiting on
  every later wait for the life of the process.
- Phone: `ITSAppUsesNonExemptEncryption` is false, so uploads stop asking about
  export compliance. The licences page names the current psychmetal. Dead
  `developer_catalogue.py` is removed and `ring_check.py` moves to `python/`, so
  neither ships in the app. FRAME-TIMING.md and SUBMISSION.md are current.
- Release tree: AUDIT-0.7.2.md, ROADMAP-0.8.0.md and DEVELOPMENT-VALIDATION.md
  are removed (they remain in the 0.8.0 folder); READBACK-0.7.2.md is READBACK.md;
  the acceptance matrix is in VALIDATION.md. `setup.py` raises a deployment
  target below macOS 14 to 14, so a wheel is never labelled for systems it
  cannot run on. Stale version labels and paths in the docs are corrected.

## 0.8.0 — 2026-10-10

October 10 review changes (rebuilt against macOS/iOS SDKs and checked with the
scripted presenter and native sanitizer suite; physical-device limits are in VALIDATION.md):

- Corrected: a playing timeline held the Python binding's engine lock, so a
  second thread could not read the mouse, touches or keys, or even wait, until
  playback ended; and any helper thread's call made a main-thread experiment's
  calls fail. Calls now hold the engine in one of three ways: alone (anything
  that changes it), reading (input, beside a playing timeline; readers serialized),
  or not at all (`wait_secs`, the clock). The main thread waits up to 50 ms
  before reporting the engine in use. Exit no longer waits forever for a thread
  stuck in the engine.
- Corrected: a stop that arrived after Python's check but before native playback
  started was erased, and the timeline played to the end. A cancellation is now
  kept until a playback ends by it; `start()` and `run()` clear it
  (`cancel_timeline(False)`). MATLAB/Octave `UpdateTimeline` and `CancelTimeline`
  are removed: nothing can call them while `PlayTimeline` blocks, and an idle
  cancellation would now end the next playback.
- Corrected: a timeline's result could not show skipped refreshes. With the
  display link the reported time equals the planned one by construction, and a
  refresh-rate drop went unseen. The result now counts, from the display's own
  reports of each frame, samples `shown`, `late` (and `lateRefreshes`,
  `firstLateSample`), `meanSampleMs` (from which the stimulus's actual frequency
  follows) and `longestIntervalMs`; `slipCount`, `lastSlipSample` and
  `lastSlipRefreshes` are gone, and playback no longer adds to FlipInfo's slip
  counters. The timeline demos print the new fields. A QueueFlip frame still
  pending, or an iOS app no longer in front, is refused before the scene is
  consumed. The loop reads only Escape each frame, not the whole keyboard.
- Corrected: an analytic mask with edge 0, and the built-in ellipse aperture,
  had a two-pixel antialiased band, which mixes two noise images where they meet
  into a visible ring. Edge 0 is now exactly hard: a pixel is wholly in or out by
  its centre.
- Corrected: DrawGabor turned its grating counterclockwise, MakeStimulus
  clockwise. Both are now clockwise from the right on screen. A Gabor drawn at
  an angle other than 0 or 180 degrees is mirrored from what 0.7.x drew.
- Faster: Octave's front end checks with `if`/`error` and copies by indexing
  instead of `assert` and `repmat`, which Octave runs as interpreted functions.
  Against the scripted engine: FillRect 772 to 283 us, DrawTexture 1137 to 430 us,
  GetMouse 157 to 76 us, Flip's wrapper 318 to 221 us.
- Faster: column-major (MATLAB) images are packed in tiles at every size: a
  1024 x 1024 colour uint8 image 12.2 to 3.9 ms, doubles 38 to 22 ms (x86).
- Tests: the stand-in headers declare the display link and shader compilation,
  so the engine type-checks off a Mac again; tests needing `plutil`, `rsync` or a
  built extension skip with a message. New checks: lost and spent
  cancellations, late and missing frames, input during playback, a main-thread
  experiment beside a reading thread, exactly hard mask edges (GPU test).

- Compile custom shaders with safe math on both older and current Xcode SDKs.
- Serialize native input readers to protect diagnostic counters and lazy touch
  listener installation while preserving concurrent input during playback.
- Make Mac Python builds explicitly ARM64, including when built with a
  universal2 python.org interpreter; wheel tags match the compiled architecture.
- Align embedded support Python.framework minimum OS metadata before signing,
  covering its ARM64 simulator slice as well as converted extensions.
- Add custom Metal fragment programs with a fixed 16-parameter contract, upfront
  pipeline compilation, bounded cache, mask/blend/clip support and retained
  queued resources. Add matching Python/MATLAB/Octave and phone spiral demos.
- Add validated linear keyframes and atomic live procedural parameter updates
  to native timelines. Rendering never waits for a live-update lock.
- Persist phone timing reports, output and matching environment metadata locally.
  Add explicit iPhone/iPad system sharing, cancellation and report reopening.
- Collect cyclic Python garbage on the idle main thread in the phone GUI,
  avoiding worker-triggered collection of detached UIKit objects. Main Thread
  Checker acceptance remains required; desktop toolbox GC is unchanged.

- Add masked still-image drawing through the shared native engine, with analytic
  and image-mask multiplication, crop/rotation/filter/tint/alpha controls and
  retained source/mask versions in queued frames and captured timelines.
- Add matching draggable image-aperture demos for Python and MATLAB/Octave,
  plus a phone catalogue entry. Physical GPU/device acceptance remains pending.
- Defer video and audio to future releases; neither is part of 0.8.0.

- Add reusable analytic GPU masks: Gaussian, ellipse, annulus and raised cosine.
  Coverage geometry is independent of noise grain/grating frequency and can
  multiply an image mask, built-in aperture and opacity. Default mask demos now
  use an analytic recipe; image-file masks remain supported.
- Export the 0.8.0 environment/timeline/recent-frame APIs through Python __all__
  and exercise them in the inventory alongside the new mask constructor.

- Add native captured-scene playback with frame-counted contrast, phase and
  position tracks. Python and MATLAB/Octave queue a scene once; the native
  engine advances it without host callbacks between frames. Atomic cancellation
  and Escape/three-finger exit retain the existing presentation backends.
- Add fixed-scene timeline demos with measured-refresh frequency labels and
  even frame periods, plus a Diagnostic-mode phone menu entry. Physical-device
  acceptance remains pending.
- Add shared native environment metadata and strict, explicit Python JSON export.
- Read strided double views safely even when their buffers are unaligned.
- See VALIDATION.md for remaining physical-device acceptance.

## 0.7.2 — release candidate, 2026-10-09

- Preserve unknown/variable display refresh as 0 in mode queries. Optional refreshHz
  on Resolution (refresh_hz in Python) selects a reported rate within 0.01 Hz.
  Prefer full pixel backing, preserve the current refresh among equal-resolution
  modes, and otherwise prefer the faster rate; never silently substitute a rate.
- Match Mac AppKit screens by the selected CoreGraphics display ID. A missing
  match fails rather than presenting on another monitor or a mirrored rectangle.
- Procedural-only passes avoid texture-retention allocations and callbacks;
  texture-only/procedural-only passes no longer reserve an unused shape buffer.
- iOS display-link presentation no longer runs a duplicate empty CADisplayLink
  on the main thread. Direct mode retains its refresh request. Both platforms
  explicitly use the same unmanaged SDR layer policy; no new color calibration
  or photon-timing guarantee is claimed.
- Carry forward the shape-batch alignment correction using baseInstance,
  App Store static-library exclusion, pre-sign framework deployment metadata,
  and public app copy corrections from the 0.7.1 submission builds.
- Octave build target accounts for its installed runtime libraries, avoiding a
  misleading macOS-14 target when the linked Octave runtime requires macOS 26.
- Version labels and package requirements are 0.7.2; phone build resets to 1.
  The existing 0.7.1 GitHub release and App Store submission are not replaced.

## 0.7.1 — 2026-10-08

- iPhone presentation defaults to CAMetalDisplayLink on iOS 17+. The same native
  backend is available explicitly on macOS 14+. Rendering is committed before
  the drawable's `present`; display-link drawables never use timed presentation.
  Unsupported prepared/queued/prefetch operations fail explicitly.
- Blob-array frequencies use measured refresh timing and even integer frame
  periods (2, 4, 6, 8, then powers of two down to approximately 1 Hz). Uniform
  cosine samples include both extrema, use frame-count indexing, and show
  measured-frequency labels. Mouse/finger dragging and deliberate overlap remain.
- GetImage reads into a reusable shared Metal buffer, with SIMD Python RGB
  conversion and tiled MATLAB/Octave conversion. Python `get_image(..., out=...)`
  reuses a writable contiguous output array. Crops and 8/10-bit results remain.
- Python `recent_frames` supplies bounded, non-draining presentation history.
  Optional desktop missed-frame inspection remains synchronous and may affect
  timing; the phone app never enables image capture or pauses on long intervals.
- Phone Diagnostic mode defaults off. It reveals Frame timing and enables
  interval graphs, stage statistics, long-interval event details and bounded
  garbage-collection correlation. Reports and full printed output open in
  separate scrollable pages. Presentation-comparison demos were removed.
- New native phone gallery with static stimulus previews, a centered Gabor and
  overlaid psychometric curve, visible 0.7.1 beta version, teaching notes, offline
  help/privacy/licenses, and three-finger return without an overlay exit button.
  All nine shared non-keyboard demos are included with portrait/touch adaptations.
- All stationary/scrolling, fine/coarse annulus demos use a centered noise square
  with black margins. Rings can move fully outside the noise square while
  maintaining the carrier's noise-cell alignment.
- User phone testing identified Xcode debugging as the source of recurring long
  intervals: the user reported none after disconnecting it. This observation
  does not establish physical onset accuracy or timing on every device.
- App Store preparation files, icons and privacy resource are included. Signed
  archive review, public support/privacy hosting, screenshots and App Store
  submission are separate and have not been completed. See VALIDATION.md.
- Build 4 (App Store correction, 2026-10-09): embed the upstream OpenSSL privacy
  manifests for Python's `_ssl` and `_hashlib` in every iOS support slice before
  framework signing, fixing ITMS-91061. Record: phone/store/BUILD-4-0.7.1.md.

## 0.7.0 — 2026-10-07

- New `PsychMetalBlobArrayDemo` and `python/blob_array_demo.py`: labelled Gaussian blobs counterphase from refresh/2 down to about 1 Hz. Press-hold dragging with a mouse or one finger, release to stop, and intentional overlap. The phone app lists the demo. Automated checks cover Nyquist phase, layouts and mouse/finger interaction; visual acceptance is pending. See BLOB-ARRAY.md.
- Add MakeStimulus and DrawStimulus, with matching Python functions, for reusable GPU noise/grating descriptions.
- Separate carrier scale from uploaded masks and built-in rectangle, ellipse and Gaussian apertures.
- Snapshot per-draw parameters and retain mask texture versions through GPU completion.
- Add matching mouse-controlled demos, native validation/lifetime tests and a real-Metal pixel test.
- Native modules built; hardware acceptance and timing remain pending. See GPU-STIMULI.md.
- iPhone and iPad, from Python: a second platform layer for the same engine. Built for iOS 15 and later and run on an iPhone 18 Pro at 120 Hz; nothing there has been timed. See IOS.md for what has been seen and what is known not to carry over. The engine's Mac-only code (AppKit window, display capture, modes, event taps, the IO registry) sits between `#if !PM_IOS` and `#endif`; the iPhone's is `PsychMetalIOS.h`. The Mac build is meant to be unchanged.
- New `TouchEvents` (`touch_events`; engine `touchEvents`): every finger's contacts with their own times, as n×5 `[time finger phase x y]`. On an iPhone it is the touch screen. On a Mac it is the trackpad, each finger placed in the window as it is on the trackpad; the window's view is one that can take them (`PMTouchView`) and is told to at the first call, which returns nothing; where the experiment runs on the main thread each call delivers the waiting AppKit events itself. The Mac's side is written and type-checked, not yet run.
- On an iPhone fingers are the mouse and one key: one is the pointer, a second down is button 1, a third is Escape. A program written for a mouse and a keyboard runs unchanged. `tests/test_fingers.py` runs these rules.
- `phone/`: an app (Briefcase) that lists this package's demos and tests, runs them as they are, and shows what they print.
- Python: `start(fn, done=...)` runs an experiment on a thread of its own and returns, for a program whose main thread runs its own loop (an app); `stop()` ends it at its next frame. A psychmetal call from the main thread while another thread is inside the engine now raises instead of waiting, which could never have ended.
- `tests/test_typecheck.py` checks the engine for the Mac and for the iPhone: against stand-in headers elsewhere, against the real SDKs on a Mac with Xcode.

## Earlier releases

0.1.0 to 0.6.0 are in the repository's docs/changelog-0.1-0.6.md, and each
release at its tag.
