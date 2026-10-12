# PsychMetal 0.9.0 code review: Apple practice, GPU use, workarounds, bloat

October 12, 2026. Version 1.

## Scope and how far to trust this

Read in full: `PsychMetalEngine.mm` (4,147 lines), `PsychMetalShaders.metal`,
`PsychMetalDisplayLink.h`, the iOS window and input code in `PsychMetalIOS.h`,
`PsychMetalKeyboardQueue.h`, and the three audio files (written or reworked in
this release). Surveyed for structure, size and duplication only: the front
ends (`PsychMetal.m`, `python/psychmetal/__init__.py`, `PsychMetalPython.cpp`,
`PsychMetalMex.cpp`), the demos, the phone app and the tests.

Statements about Apple's guidance are from what I know of the documentation.
I did not re-check them against Apple's current pages for this review. Nothing
here has been measured; several items say what to measure before changing
anything.

Source size: about 27,500 lines, plus about 8,300 lines of tests.

## Already the proper way

- **Drawing is on the GPU.** Shapes are instanced quads with analytic
  antialiasing in the fragment shader. Gabors, noise (a hash on the GPU, no
  CPU image), apertures and masks, linearization (power or table) and offscreen
  windows all run in shaders. Custom shaders compile once and are cached by
  source. No frame uploads a CPU-generated carrier.
- **Presentation timing uses Apple's documented feedback.** Frames are presented
  with `presentDrawable:atTime:`, and their times come from `addPresentedHandler`
  and `presentedTime`. GPU times come from `GPUStartTime`/`GPUEndTime`. On macOS
  14 and iOS 17 there is a `CAMetalDisplayLink` path.
- **iPhone refresh rate:** the frame-rate range is set on a display link, and
  `CADisableMinimumFrameDurationOnPhone` is in Info.plist; that is Apple's
  mechanism for ProMotion.
- **Audio:**
  - The Mac uses the HAL output unit; iOS uses `AVAudioSession` with RemoteIO.
  - Microphone permission goes through `AVAudioApplication`, with fallbacks for
    older systems.
  - Rate conversion uses `AudioConverter` at its highest quality.
  - The render and capture callbacks take no locks and allocate nothing; they
    talk to the rest of the program through fixed lock-free rings.
  - Device notices on the Mac now arrive through block listeners on a queue of
    PsychMetal's own.
- **Debugger detection** uses `sysctl` and `P_TRACED`, Apple's documented
  technique.

## Fix before 0.9.0 (small, low risk)

1. **A deprecated call.** `[app activateIgnoringOtherApps:YES]`
   (`PsychMetalEngine.mm`, prepareApp) is deprecated from macOS 14. Every Mac
   build targets 14 or later, so `[NSApp activate]` replaces it with no fallback
   needed. Nothing else deprecated is called; the one suppressed warning
   (`fastMathEnabled`, custom shaders) is behind an availability check, as Apple
   intends.

2. **Twelve MATLAB-only probes shipped in the package.** These are:
   - CallerSleepProbe, CompositorProbe, DrawableCompare, InputLatencyProbe and
     MixedCadenceProbe;
   - LatchTest, TearTest and WhenTest;
   - RateCompare, ScheduleSweep, WarmupLength and FrameStats;
   - plus `comparisons/PTB*.m`.

   Together that is 2,434 lines. No document except the CHANGELOG mentions them,
   no test runs them, and none has a Python version, so they break the parity
   rule and grow the package. They were development experiments. Recommendation:
   move them out of the release folder, to a `probes/` folder at the repository
   root, outside the release manifest. This is your call.

## Workarounds worth replacing (0.10.0)

3. **Event times are guessed.** `eventTime()` (`PsychMetalEngine.mm`, about line
   403) tries four interpretations of `CGEventGetTimestamp` (nanoseconds or mach
   ticks, with or without sleep time) and keeps whichever lands within 5 s of
   now. Converting the tapped event with `[NSEvent eventWithCGEvent:]` and using
   its `timestamp` gives seconds on the uptime clock, the same as
   `CACurrentMediaTime`, with no guessing. Confirm the two agree on one Mac
   first.

4. **Keyboard timing combines two sources.** The keyboard queue polls 128 keys
   with `CGEventSourceKeyState` every 2 ms and reconciles the results with event-tap
   events using a 20 ms grace window. The direct Apple route for timestamped key
   events is `IOHIDManager` with value callbacks, which carry timestamps. It
   needs the same Input Monitoring permission the tap does, and it would replace
   both sources and the reconciliation. The modifier masks in the tap
   (`0x00000002` and so on) should use the `NX_DEVICE…KEYMASK` names.

5. **A fixed one-second wait at Open.** `settleAppKit(1.0)` runs the main run
   loop for a second before checking the window's position, and close waits
   0.25 s. Waiting for the window to be on screen instead
   (`NSWindowDidChangeOcclusionStateNotification`, or the screen and frame
   checks with a timeout) would end as soon as AppKit is ready.

6. **Display capture.** `CGDisplayCapture` plus `CGShieldingWindowLevel` is the
   pre-Lion way to get the compositor out of the path. On current macOS, an
   opaque full-screen `CAMetalLayer` gets direct presentation without capture,
   and Apple discourages capture for applications. Measure with the tear test and
   the compositor probe before dropping it; if capture shows no difference, it,
   and the warning about it, can go.

7. **Precise waits busy-spin.** `pm::waitUntil` sleeps, then spins for at least
   4 ms (up to 20 ms after a late wake) on every call. Apple's documented
   route to punctual wake-ups is a time-constraint thread policy
   (`THREAD_TIME_CONSTRAINT_POLICY`), or an audio workgroup for audio. Measure
   wake-up error with and without the spin on an M-series Mac and an iPhone
   first. The spin costs power, and on a phone, heat.

8. **Shaders compile at every Open.** The built-in shaders are embedded as
   source and compiled with `newLibraryWithSource:` each time a window opens,
   then 18 pipelines are built synchronously for the window (more on first use of
   linearization or offscreen windows). Apple recommends
   compiling at build time. `xcrun metal` → `.metallib`, embedded as bytes and
   loaded with `newLibraryWithData:`, keeps the single-file MEX and removes the
   runtime compile. Custom shaders still compile at run time, as they must.
   Measure Open's time first.

9. **Two undocumented sources.**
   - `LinkInfo` reads DisplayPort link state from IORegistry entries that are
     not a documented interface (about 110 lines, stated as such in the code).
   - `KbQueueStatus` reads `kCGSSessionSecureInputPID` from
     `CGSessionCopyCurrentDictionary`.

   Both fall back to "unknown", but either can change without notice. Keep them
   as stated diagnostics, or drop them; there is no documented replacement for
   either.

## Not on the GPU, and could be

10. **Polygons are rasterized on the CPU.** CoreGraphics draws each polygon into
    a coverage mask, which is then uploaded. The mask is cached by shape, so a
    polygon that only moves costs nothing, but one that rotates or deforms on
    every frame is rasterized and uploaded on every frame. A GPU version would
    triangulate the polygon (or fill it by stencil, then cover) and antialias it
    in the shader. Worth doing only if changing polygons are needed.

    Text is also rasterized on the CPU, by CoreText, and cached. That is right:
    Metal has no text, and Apple's text stack is CoreText.

11. **Float images are halved on the CPU.** `uploadTexture` converts float
    images to half floats on the CPU before upload. That is cheap next to the
    copy itself and stays as is, unless large float textures are updated on every
    frame.

## Bloat and duplication

12. **The front ends duplicate logic.** `PsychMetal.m` and
    `python/psychmetal/__init__.py` each carry their own:
    - text wrapping;
    - key-name table;
    - colour and rectangle expansion;
    - noise-argument and stimulus/mask parameter packing;
    - audio tone ramping.

    Each piece is written twice, and parity depends on keeping the two in step;
    the tests are what check that today. Moving them into `PsychMetalShared.cpp`,
    where some shared validation already lives, would make one implementation
    serve both. This is the largest structural simplification available.

13. **Presentation has many modes and knobs:**
    - Flip, direct or through the display link;
    - QueueFlip, with its presenter thread;
    - PrepareFlip/PresentNow;
    - drawable prefetch;
    - display sync off;
    - wait-for-confirm;
    - WaitToDraw, NextPhase and NextRefresh;
    - PlayTimeline, with keyframes and live updates.

    PrepareFlip/PresentNow, prefetch and display sync off are used only by the
    inventory and hardware tests and by the probes in item 2. They are research
    instruments. If they have answered their questions, removing them
    simplifies the engine's locking and record-keeping noticeably. Your call.

14. **Duplicated shader code.** Gabors and noise are computed twice: in the
    batched shape shader (`sfmain`, kinds 6 and 7, used by DrawGabor and
    DrawNoise for thousands of patches in one draw) and in the procedural
    stimulus shader (`pfmain`). Both paths have reasons to exist. Their math
    could be shared Metal functions, so a change to one cannot diverge from the
    other.

15. **Diagnostic returns about 70 fields.** These include window, view, layer
    and screen frames, activation policies, mach timebase, safe-area insets and
    key-scan timing. Most of these answered questions during development. A
    shorter report, with the rest behind an option, would be easier to read
    and to keep correct.

16. **The CHANGELOG is 90 KB.** Older entries could move to the release notes of
    their versions, leaving the CHANGELOG to recent releases.

## Audio, beyond the above

17. **Detecting interruptions directly.** iOS gave no notice for Siri
    (AUDIT-0.9.0.md, limit 5). A gap in the output callbacks' sample times
    against their host times would detect any interruption, from any cause, on
    both systems, without depending on notifications. Deferred with the
    interruption policy.

18. **Separate input and output units.** On a Mac where input and output are
    the same device, one HAL unit with input enabled would replace two units.
    Two units are correct and simpler to reason about when the devices differ;
    leave it.

## Recommendation

Before 0.9.0: item 1, and item 2 if you agree. Everything else changes
behaviour that has been validated on hardware, so it belongs in 0.10.0, each
change with a measurement before and after. Items 12 and 13 do the most for
size, item 3 for correctness, and items 7 and 8 for power and start-up time.
