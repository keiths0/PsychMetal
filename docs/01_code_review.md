# PsychMetal — code review

> **Historical. Reviewed 0.1.x, which is four releases behind.** `PsychMetalCore.mm`
> has since gone from 693 lines to roughly 3,000 and `PsychMetal.m` from 269 to
> 1,323. The P0 and P1 items below were addressed; the line numbers do not point
> at anything current. Kept because the reasoning about surface reuse, the lock
> discipline and the completion-versus-presentation barrier is still the basis of
> the present design, and because it records what the code looked like before the
> Metal drawing path existed. For current behaviour see `05_results.md` and the
> package `README.md`.

Reviewed: `PsychMetalCore.mm` (693 lines), `PsychMetal.m` (269), `PsychMetalDirectDemo.m` (68), `Makefile`, `README.md`.

Overall: the architecture is sound and the hard part is right. Attaching the IOSurface directly as `GL_COLOR_ATTACHMENT0` of PTB's existing offscreen FBO — instead of blitting — is the correct move, and waiting for command-buffer completion (not presentation) before reusing a surface is the right reuse barrier. The lock discipline is mostly careful. What follows is ordered by severity.

---

## P0 — Correctness bugs

### 1. Nil drawable permanently wedges its IOSurface

`PsychMetalCore.mm:90–102`. When `u.drawable` is nil the callback sets `status`/`done` and returns without ever committing a command buffer. `gpuDone` is only set in `addCompletedHandler` (line 151), which never runs. But `enqueue` already recorded `lastBufferToken[b] = t` (line 524), so two flips later:

```
waitBuffer(b) → r->gpuDone == 0 forever → 2 s stall → fail("Buffer reuse timeout.")
```

A single dropped drawable — which is *expected* occasionally with `maximumDrawableCount = 2` and `preferredFrameLatency = 1` — aborts the experiment. Fix:

```objc
if (!d) {
    pthread_mutex_lock(&lock);
    r = recordFor(token);
    if (r) { r->status = 4; r->done = 1; r->gpuDone = 1; }   // 4 = no drawable
    activeLinkCallbacks--;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    return;
}
```

Note the status change from `2` to a new code. Currently `status = 2` is indistinguishable from "pending" once `historyMatrix` applies `r->done ? r->status : 2` (line 611), so nil-drawable drops are invisible in the diagnostics — exactly the failure mode you most need to see. Add `4 = drawable unavailable` to `PsychMetal.m`'s `actualStatus` documentation and to `Diagnostic`'s help text.

### 2. `mexErrMsgIdAndTxt` / `mexWarnMsgIdAndTxt` called from a main-queue block

`openCore` lines 355 and 363 issue `mexWarnMsgIdAndTxt` inside the `onMainSync(^{...})` block. When the MEX is *not* running on the main thread (Octave with a GUI front end), that block executes on the main queue, and MEX API calls are only legal on the interpreter thread. Worse: under MATLAB, `mexErrMsgIdAndTxt` unwinds via `longjmp`. Longjmping out of a `dispatch_sync` block corrupts libdispatch's queue state.

Collect a diagnostic string inside the block and emit it after `onMainSync` returns:

```objc
__block NSString *pendingWarning = nil;
onMainSync(^{ ... pendingWarning = [NSString stringWithFormat:...]; ... });
if (pendingWarning)
    mexWarnMsgIdAndTxt("PsychMetal:DisplayMapping", "%s", pendingWarning.UTF8String);
```

### 3. `mxCreateDoubleMatrix` called while holding the mutex

`historyMatrix` (line 598) allocates a MATLAB array with `lock` held. Two problems: MATLAB's allocator can `longjmp` on out-of-memory, leaving `lock` permanently held (every subsequent call deadlocks); and it holds a lock the display-link callback contends on across an unbounded allocation. Snapshot into a `std::vector<Record>` under the lock, unlock, then build the `mxArray`.

The same pattern applies to line 411's `mexErrMsgIdAndTxt` for the drawable-size mismatch — by that point `device`, `queue`, `metalWindow` and a fullscreen Space exist. The longjmp skips `closeCore()`, so the user is left staring at a black fullscreen window with no display link and no way to dismiss it. **Every `fail()` / `mexErrMsgIdAndTxt` inside `openCore` after the window is created should call `closeCore()` first.** A small RAII guard or a `goto cleanup` before each error path handles this.

### 4. `fail()` is not marked `noreturn`

`waitScheduled` (lines 556–562):

```objc
if (!r) { pthread_mutex_unlock(&lock); fail("Unknown or expired frame token."); }
struct timespec d = deadline(2);
while (!r->scheduled)     // NULL deref if fail() ever returns
```

Under Octave, `mexErrMsgIdAndTxt` throws a C++ exception, so this is fine in practice — but the compiler can't prove it, and the code reads as a latent null dereference. Add `__attribute__((noreturn))` (or `[[noreturn]]`) to `fail`.

### 5. Unchecked Metal texture creation

Line 458: `textures[i] = [device newTextureWithDescriptor:td iosurface:... plane:0];` is never nil-checked. It appears only in the *error message* of the subsequent `CGLTexImageIOSurface2D` check, which won't fire if the GL side succeeds. A nil texture reaches `setFragmentTexture:` in the display-link callback and you get a black frame with no explanation. Check it explicitly, and also verify `IOSurfaceGetBytesPerRow(surfaces[i])` matches what Metal expects.

Relatedly, `makeSurface` hardcodes the row-byte alignment as `(w*4+63) & ~63`. Use `IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)` instead — the required alignment is device-dependent and 64 is not guaranteed on every GPU family.

### 6. No argument validation in `mexFunction`

`mxGetScalar(prhs[k])` is called on all 10 `Open` arguments with no `mxIsNumeric` / `mxIsScalar` check. Passing a string or an empty array is undefined behaviour rather than a clean error. A three-line helper (`static double arg(const mxArray*, const char*)`) that validates and returns fixes all call sites.

### 7. No `@available` guard

`CAMetalDisplayLink` is macOS 14+. The Makefile sets `-mmacosx-version-min=14.0`, but if the MEX is loaded on macOS 13 you get a hard crash at `[[CAMetalDisplayLink alloc] init...]` rather than a message. Wrap the creation in `if (@available(macOS 14.0, *)) { ... } else fail("PsychMetal requires macOS 14 or later.");`

---

## P1 — Timing and design

### 8. The demo validates the prediction against itself

`PsychMetalDirectDemo.m`:

```matlab
results = [diag.projectedTimestamp diag.frameID zeros(size(diag.frameID)) diag.scheduledAt diag.displayLinkTick];
valid   = m(:,3) == 0;                 % always true — column is literally zeros
intervals = diff(v(:,1)) * 1000;       % diff of the *projected* timestamps
```

The headline `Presented median/p99/max` line is computed from `projectedTimestamp`, which is by construction `rawTarget + lag*ifi` on a monotonic tick sequence — it will look near-perfect whether or not frames actually landed. For a project whose entire purpose is demonstrating better timing than the Vulkan path, this is the one number that has to be real. Use `diag.actualTimestamp` with `diag.actualStatus == 0`, and report the confirmed-vs-total ratio prominently.

The demo already draws `Screen('FillRect', target, 255*mod(k,2), [0 0 140 140])` — a perfect photodiode patch. The README should say so explicitly and describe the external-validation procedure; that is the claim that will convince reviewers, not `presentedTime`.

Also: `prctile` needs the Statistics Toolbox (MATLAB) or the `statistics` package (Octave), and `dlmwrite` is deprecated. Both make the demo fail on a stock install. Replace with a two-line sorted-index percentile and `writematrix`/`csvwrite` with a fallback.

### 9. Display link runs on the host's main run loop

`driver.link addToRunLoop:NSRunLoop.mainRunLoop` (line 502). The delegate therefore fires on whichever thread pumps that run loop, which is the same thread that blocks inside `pthread_cond_timedwait` in `waitScheduled` and `waitBuffer`. Under MATLAB desktop, the MEX runs on the main thread — so during every `Flip` you are blocking the exact run loop the display link depends on, and you are also sharing it with AppKit event delivery, window-server messages and MATLAB's own UI work.

That it works at all suggests the callback is being delivered off the main run loop in practice, but relying on that is fragile. The robust pattern (and what CVDisplayLink-based PTB effectively does) is a dedicated thread:

```objc
NSThread *t = [[NSThread alloc] initWithBlock:^{
    [driver.link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    driver.link.paused = NO;
    while (!linkThreadShouldExit)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}];
t.qualityOfService = NSQualityOfServiceUserInteractive;
t.threadPriority = 1.0;
[t start];
```

This decouples presentation timing from anything the interpreter thread does, and lets you raise the thread's QoS without raising MATLAB's. I'd treat this as the single highest-value structural change.

### 10. `glFinish()` on the flip critical path

Line 512. `glFinish` drains *all* GL work in the context, not just this frame's, and blocks with a spin. A scoped fence is strictly better and gives you a measurable number:

```objc
GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
glFlush();
GLenum w = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 100 * 1000 * 1000);
glDeleteSync(fence);
if (w == GL_TIMEOUT_EXPIRED) fail("Timed out waiting for OpenGL rendering to complete.");
```

Record the wait duration into the `Record` and surface it in `Diagnostic` as `glSyncMs` — if this is consuming milliseconds, that's a headline finding about where the frame budget goes.

### 11. Single pending slot limits jitter tolerance

`pendingBuffer` holds exactly one frame (line 39), so the pipeline is: draw → queue → the link picks it up on the next tick. If the interpreter is late by even a fraction of a refresh, the tick passes with nothing pending and a refresh is dropped. Generalizing to a small ring of 3 IOSurfaces and a 2–3 deep pending queue would let a late frame catch up without a drop, at the cost of one extra frame of latency. Worth making it a parameter (`PsychMetal('OpenWindow', screen, 'BufferCount', 3)`) and measuring both.

Similarly, `preferredFrameLatency = 1` (line 499) is the aggressive setting; Apple's guidance is 2 for stability. Expose it and report drop rate at each.

### 12. `Missed` is effectively always 0

`PsychMetal.m:113–114` sets `missed = 0` unless scheduling failed outright. Real `Screen('Flip')` returns a positive number when the deadline was missed, and experiment code branches on it. You already have the information: in `enqueue`, `requested = lastTargetTick + 1` gets clamped to `earliest = ticks + 1` when the loop fell behind (line 528). Return `pendingTargetTick - requested` as the miss count and propagate it. Right now a program ported from `Screen` will silently believe every frame landed.

### 13. Colour management is unspecified

`layer.colorspace` is never set, so the CAMetalLayer inherits the display's colour space and no conversion is applied — which happens to be what PTB assumes, but only by accident. On a P3 display, or if a future macOS changes the default, your luminance calibration silently shifts. For psychophysics this deserves an explicit `layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)` (or a documented pass-through), `layer.wantsExtendedDynamicRangeContent = NO`, and a sentence in the README stating the assumption.

### 14. `ifi` comes from PTB with `SkipSyncTests = 2`

`PsychMetal.m:49` sets `SkipSyncTests = 2` before `Screen('OpenWindow')`, so `Screen('GetFlipInterval')` returns the nominal OS value rather than a measured one — and that value then drives `CAFrameRateRangeMake(hz, hz, hz)`. You already capture `selectedDisplayID` (line 366) but never use it. Cross-check with CoreGraphics and warn on disagreement:

```objc
CGDisplayModeRef m = CGDisplayCopyDisplayMode(selectedDisplayID);
double hz = CGDisplayModeGetRefreshRate(m);   // 0 on some internal panels
CGDisplayModeRelease(m);
```

Better still, derive the true interval from the display-link tick timestamps during the warmup frames and report it in `summary` — that is a measurement the Vulkan path can't give you and is a selling point.

---

## P2 — Robustness and API

### 15. `Screen('GetWindowInfo', buffer)` as a side effect

`PsychMetal.m:61` relies on `GetWindowInfo` incidentally selecting the drawing target. That's undocumented behaviour that could change between PTB releases and would fail silently and catastrophically (the core would capture the *host's* FBO). A degenerate drawing command is the documented way to force a target switch:

```matlab
Screen('FillRect', buffer, 0, [0 0 1 1]);   % forces buffer to become the drawing target
```

Add a sanity check in `openCore`: the captured FBO's current `GL_COLOR_ATTACHMENT0` texture name should equal the `tex0` passed in. If it doesn't, you captured the wrong FBO — fail loudly rather than rendering the host window's contents.

### 16. `Screen('Rect', screen, 1)` for physical pixels

Line 44. The `realFBOSize` flag is documented for *window* handles; its behaviour for a bare screen number is not guaranteed. Since a mismatch here trips the hard error at `PsychMetalCore.mm:411`, it's worth deriving the physical size defensively (e.g. `Screen('Resolution', screen)` cross-checked against the drawable) and giving a clearer remedy in the error text than "refusing to scale".

### 17. Persistent state can desynchronize

`S` is a `persistent` in `PsychMetal.m`. `clear PsychMetal` wipes it while the MEX keeps the window and display link alive — leaving an undismissable fullscreen window. Consider a `PsychMetal('CloseAll')` that calls `PsychMetalCore('Close')` unconditionally, mention it in the help, and have `OpenWindow` call it defensively instead of only asserting `isempty(S)`.

Also: `Close` doesn't `ShowCursor` or reset `Priority`, and `OpenWindow` never calls `HideCursor` — a visible pointer over the stimulus is easy to miss in a dark room.

### 18. Input validation via `==` on possibly non-scalar args

`assert(numel(varargin) >= 2 && varargin{1} == S.buffer, ...)` in `MakeTexture` (line 84) errors confusingly if `varargin{1}` is a matrix. Use `isscalar(varargin{1}) && isnumeric(varargin{1}) && varargin{1} == S.buffer`. Same pattern in `Flip`, `Diagnostic`, `Close`.

### 19. O(NREC) scans under the lock

`closeCore`'s drain loop and `drainRecords` walk up to 16 384 records on every condition-variable wakeup while holding `lock`. Track `inFlightCount` (incremented on submit, decremented when both `done` and `gpuDone` are set) and wait on that instead. Cheap change, removes a pathological case.

### 20. `pthread_cond_timedwait` against `CLOCK_REALTIME`

`deadline()` uses wall time, so an NTP step or a manual clock change perturbs every timeout. macOS provides `pthread_cond_timedwait_relative_np`, which is monotonic and simpler:

```objc
struct timespec rel = { .tv_sec = 2, .tv_nsec = 0 };
pthread_cond_timedwait_relative_np(&cond, &lock, &rel);
```

(Note the semantics differ on spurious wakeup — the relative timeout restarts — so keep an absolute `CACurrentMediaTime()` deadline in the loop condition.)

---

## P3 — Build, packaging, repo

- **Implicit narrowing at every `openCore` call site.** `mxGetScalar` returns `double` and is passed straight into `NSUInteger` / `GLenum` / `GLuint` parameters. With `-Wall -Wextra -Wpedantic` this should be producing conversion warnings; add explicit casts so real warnings aren't buried. Consider adding `-Wconversion` and, in CI, `-Werror`.
- **Missing includes.** `strcasecmp` needs `<strings.h>`; `memset`/`strlen` need `<string.h>`. Currently pulled in transitively via the Cocoa headers, which is fragile.
- **`mxGetPr` is legacy.** Build with `-R2018a` and use `mxGetDoubles`, or document why not.
- **Apple silicon only.** The Makefile hardcodes `-arch arm64` and `mexmaca64`. State this in the README, and have the Makefile fail with a clear message on `uname -m == x86_64` rather than producing a MEX that MATLAB won't load.
- **Binaries committed to the repo.** Shipping `.mex`/`.mexmaca64` in git bloats history and complicates the trust story. GitHub Releases with attached, checksummed artefacts is cleaner; keep the repo source-only and let `.gitignore` cover the MEX files.
- **No CI.** A single GitHub Actions `macos-14` job running `make octave` catches compile breakage for free. A headless runner can't test presentation, but it can compile and it can run a smoke test that verifies the MEX loads and rejects bad arguments.
- **No version or CHANGELOG.** Add a `PsychMetal('Version')` command returning a semantic version and the build date — invaluable when someone reports timing numbers six months from now.
- **README says "Octave application" twice** (the notch/safe-area and `Info.plist` discussion) where it means MATLAB *or* Octave.
- **Consider a `PsychMetal('SelfTest')`** that opens, runs ~300 frames, and asserts on the confirmed-presentation rate and interval distribution. That gives users a one-line way to report whether it works on their hardware, which is what you'll want when collecting reports across macOS versions.

---

## Suggested order of work

1. Fix the nil-drawable `gpuDone` bug (#1) — it's the one that will bite a real experiment.
2. Fix the demo's self-validating metric (#8) — it's the one that undermines the result.
3. Cleanup-on-error in `openCore` and the main-queue MEX-API calls (#2, #3).
4. Move the display link to a dedicated thread (#9).
5. Make `Missed` meaningful and add the drop/no-drawable counters to `Diagnostic` (#12, #1).
6. Everything else.

---

*Reviewed from the uploaded `PsychMetal.zip`. I did not have the GitHub repository URL — if you share it I can also look at the issue templates, Actions config, and commit history.*
