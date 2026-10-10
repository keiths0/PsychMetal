# PsychMetal 0.7.2 engineering audit — October 9, 2026

This is a separate, unpublished candidate. The 0.7.1 app under Apple review and
its source folder have not been changed by this audit.

## Fixed

- Procedural-only draw passes no longer allocate a shared texture-retention vector
  or register a texture-retention completion callback. Only actual texture
  references are copied and held until GPU completion.
- Shape-buffer ring slots are acquired only for passes containing shapes.
  Texture-only and procedural-only passes avoid unused shape-buffer waits and
  completion callbacks. Shape slots still have session-epoch protection.
- iOS display-link presentation no longer creates a second, empty CADisplayLink
  callback on the main thread. The direct fallback retains its refresh request.
- Mac display selection now matches CoreGraphics and AppKit by display ID and
  fails explicitly if the requested screen disappeared.
- Mac mode enumeration no longer fabricates 60 Hz for modes with unknown/variable
  refresh. Resolution accepts an optional fixed Hz in all three front ends;
  selection distinguishes fractional rates and preserves the current refresh
  when dimensions/backing match and Hz was omitted.
- iOS explicitly matches the existing Mac unmanaged SDR layer policy.
- The Mac Octave build derives its minimum deployment target from its linked
  Octave libraries. The installed Octave 11.3 libraries require macOS 26, so this
  candidate's prebuilt Octave MEX accurately targets 26. MATLAB/Python target 14.
- The simulator's aligned shape-buffer binding, static-library exclusion and
  pre-signing embedded-framework deployment metadata fixes from App Store build 3
  are included in the candidate. iOS device and simulator wheels were rebuilt.

## Reviewed and retained

Native CAMetalDisplayLink supplies its drawable. The engine commits before
presenting it; it never calls timed presentation for a display-link drawable.
The native delegate handoff does not run Python/MATLAB code on the callback.
Frame-latency and rate-range requests remain best effort. Mac direct presentation
uses native Metal scheduling and remains the default for its explicit scheduling
features. This is not an OpenGL compatibility layer.

Drawable sizes are physical pixels, with HiDPI mismatch rejected. Render-pass
formats match the drawable/offscreen/float targets. Shape batches bind at aligned
buffer offset zero and use baseInstance. Texture snapshots are kept alive through
GPU completion; shutdown/reopen uses epochs to reject stale callbacks. Ordinary
windows remain framebuffer-only; readback is opt-in. GPU render failures remain
reported even when a command buffer renders offscreen without presenting.

Both platforms use unmanaged SDR output. Ten-bit buffers and linearization are
available, but hardware color depth, luminance and scanout timing need physical
measurement. No automatic color-profile conversion or HDR output was added.

## Verification and limits

See VALIDATION.md for current build and test results. The resource-lifetime test
executes the actual draw-pass setup with a CPU command-buffer double and sanitizers;
it verifies retention, callback counts, ring ownership and stale-session behavior.
The mode-selection test executes the actual selector. Front-end tests run through
the real MEX/Python binding code with a scripted engine. These are not GPU timings.

No accessible Metal GPU or active display is exposed to this execution environment.
Phone Release and simulator Debug builds verify compilation and packaging; they do
not demonstrate device timing or pixel correctness. The optimization removes
identified allocations, callbacks and waits, but no millisecond speedup is claimed.

Before release, repeat the existing hardware, inventory, motion and open-ready
tests on the Mac; check native-pixel output and fixed-refresh selection on the
actual monitor. Run phone demos from the Home Screen with Xcode disconnected,
including iPad rendering, touch/three-finger return, background recovery and reports.

Apple procedures reviewed: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink),
[preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency),
[preferredFrameRateRange](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframeraterange),
[CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer),
[colorspace](https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace).
