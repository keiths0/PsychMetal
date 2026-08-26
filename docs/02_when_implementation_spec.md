# Implementing `when` in PsychMetal

> **Historical, and superseded in 0.3.1. This document specifies a mechanism
> that has been deleted.** The design here resolves `when` to a boundary on a
> fitted refresh grid, sleeps until shortly before it, and commits — the library
> doing the scheduling. That was measured at 99% late for a request exactly four
> refreshes ahead, against 1% for committing immediately and letting
> `presentDrawable:atTime:` place the frame, which is what 0.3.1 does. Do not
> read this as a description of the current code.
>
> What survives is the *interface*: the `Screen('Flip')`-compatible semantics
> below, the canonical `vbl + (waitframes - 0.5) * ifi` idiom, and the argument
> checking. Those are still exactly right and still implemented. It is the
> machinery behind them that turned out to be an elaborate way of computing
> something the system already knew. See `05_results.md` section 9e.

Revision 2. Target: PsychMetal 0.1.1 → 0.2.0. Blocking, `Screen('Flip')`-compatible semantics.

```matlab
[vbl, onset, flipTime, missed, beampos] = PsychMetal('Flip', w [, when]);
```

`when` is the earliest acceptable presentation time in `GetSecs` units. The canonical PTB
idiom must work unchanged:

```matlab
vbl = PsychMetal('Flip', w, vbl + (waitframes - 0.5) * ifi);
```

This revision is restructured around what Apple actually documents. Metal has a
scheduled-presentation primitive (`presentDrawable:atTime:`), which changes the design, and
a documented statement about added latency on macOS that bears directly on whether the
current setup is getting direct scanout. **Phase 0 must run before any of the `when` code is
written**, because its results decide the architecture.

---

## What Apple documents

| Symbol | Documented meaning |
| --- | --- |
| `CAMetalDisplayLink.Update.targetPresentationTimestamp` | "The time the system estimates until the display of the next frame." |
| `CAMetalDisplayLink.Update.targetTimestamp` | "A deadline that indicates when your app needs to finish rendering to the drawable." |
| `CAMetalDisplayLink.preferredFrameLatency` | "The amount of time, in frames, your app requests to render a frame." Discussion: "The final latency may be bigger if the system needs more time, such as for windowed modes on macOS." Important: "The only acceptable values are `1.0` and `2.0`." |
| `MTLCommandBuffer.present(_:atTime:)` | "Presents a drawable at a specific time." Parameter is "the Mach absolute time, in seconds, that you want to present the drawable." macOS 10.11+. |
| `MTLDrawable.presentedTime` | "The host time, in seconds, when the drawable was displayed onscreen." Discussion: "The property value is `0.0` if the drawable hasn't been presented **or if its associated frame was dropped**." |

Four consequences:

1. **You are reading the correct timestamp.** `targetPresentationTimestamp` is the prediction.
   `targetTimestamp` is a different thing — your render deadline — and you are not logging
   it. It answers "how much frame budget do I actually have" directly, for free.
2. **`preferredFrameLatency` is the documented control** for how far ahead you run, it is
   restricted to exactly 1.0 or 2.0, and there is no API to read back what you were actually
   granted. Empirical measurement is therefore legitimate — but see Phase 0, because Apple
   names the condition under which extra latency is added.
3. **Metal can present at a specified time**, in the same timebase you already use. The lag
   calibration does not have to carry the scheduling burden.
4. **`presentedTime == 0` means the frame was dropped.** You query it inside
   `addPresentedHandler`, which fires after presentation, so "hasn't been presented yet" is
   largely excluded. The README's current claim that a missing confirmation "is not by itself
   evidence that the physical frame was missed" contradicts the documentation and should be
   corrected. `missingPresentedTimes` is a drop count.

---

## On fullscreen and the compositor

You are right that the window is a dedicated native-fullscreen window. That is a
*precondition* for bypassing the compositor, not a guarantee of it, and the distinction
matters here.

Modern macOS has no true exclusive-display mode. `CGDisplayCapture`, `CGLSetFullScreenOnDisplay`
and the old `NSOpenGLPFAFullScreen` path are gone or deprecated. What replaced them is an
optimization the window server applies on its own: when a single opaque layer covers an
entire display in its own Space, with a pixel format and size that need no conversion,
WindowServer hands that layer's IOSurface straight to the display controller and skips the
composite pass. There is no API to request it and no API to query whether you got it.

Your configuration satisfies the usual conditions — own Space via native fullscreen,
`opaque = YES`, `framebufferOnly = YES`, `drawableSize` matched to physical pixels with a hard
error if it isn't, no colorspace conversion, `BGRA8Unorm`. So the intent is right.

But `preferredFrameLatency`'s "the final latency may be bigger if the system needs more time,
such as for windowed modes on macOS" plus a measured nonzero `lagEstimateFrames` is precisely
the signature of *not* getting the bypass. Four things in the current setup could be quietly
preventing it:

- **The PTB host window.** `OpenWindow` leaves a real 128×96 onscreen window open for the
  whole session. Native fullscreen puts the Metal window on its own Space so this *should* be
  harmless, but it is a genuine composited window and the first thing to rule out.
- **The cursor.** Never hidden. Usually handled by a hardware cursor plane, but it is one more
  variable.
- **Notifications and the menu bar.** Any banner forces a composite pass for those frames.
  Focus / Do Not Disturb should be on for timing runs.
- **Game Mode.** Requires `LSApplicationCategoryType` to mark the app as a game. MATLAB and
  Octave do not, so you are almost certainly not getting it, despite the README implying it
  may activate.

---

## Phase 0 — Characterize before building

Five measurements. Each is small, and together they decide the rest of the design.

### 0.1 Timebase

`presentDrawable:atTime:` takes Mach absolute time; `when` arrives in `GetSecs` units. If those
differ, everything downstream is wrong by a constant. Verify rather than assume.

```objc
if (cmd(prhs[0], "Now")) {
    if (nrhs != 1 || nlhs != 1)
        fail("Now takes no arguments and one output.");
    plhs[0] = mxCreateDoubleScalar(CACurrentMediaTime());
    return;
}
```

```matlab
t0 = GetSecs; tm = PsychMetalCore('Now'); t1 = GetSecs;
skew = tm - (t0 + t1) / 2;
if abs(skew) > 1e-3
    PsychMetalCore('Close');
    error('PsychMetal:Timebase', ...
        ['GetSecs and CACurrentMediaTime differ by %.3f ms. Scheduled presentation ' ...
         'requires a common timebase.'], skew * 1000);
end
S.timebaseSkew = skew;
```

### 0.2 Read back the granted latency

```objc
driver.link.preferredFrameLatency = 1.0f;
grantedFrameLatency = driver.link.preferredFrameLatency;   // new static, report in summary
```

Expose as `summary.preferredFrameLatency`. If the setter is clamped or ignored you want to
see it, not infer it.

### 0.3 Log the render deadline

In the display-link callback, alongside `rawTarget`:

```objc
    r->renderDeadline = u.targetTimestamp;
```

Add a `Diagnostic` column and report `renderBudgetMs = (renderDeadline - scheduledAt) * 1000`.
This is the documented answer to how much drawing time you have per frame, and it replaces
inferring it from idle time in `Flip`.

### 0.4 The latency sweep — the decisive test

Run the demo twice, identically, with `preferredFrameLatency` at 1.0 and at 2.0, and compare
`summary.calibratedTargetLagFrames`.

| Result | Meaning |
| --- | --- |
| Lag tracks the setting one-for-one | The relationship is deterministic. Compute the offset from `preferredFrameLatency` instead of calibrating it, and the whole lag estimator becomes a validation check rather than a correction. |
| Lag pinned above the request in both runs | The system is adding latency — the "windowed modes on macOS" case. You are very likely still being composited. That is a finding worth reporting on its own, and it changes what the project is demonstrating. |

Repeat with the PTB host window ordered out (`Screen('Close')` is too destructive; try
`[hostWindow orderOut:]` equivalent, or open the host on a different display) and with the
cursor hidden, to see whether either moves the number.

### 0.5 Independent compositor check

`MTL_HUD_ENABLED=1` in the environment before launching MATLAB or Octave gives Metal's
performance HUD with present timing. Note that the HUD is itself an overlay and will perturb
what you are measuring, so use it as a sanity check, not as the measurement. Quartz Debug's
"Flash screen updates" (Additional Tools for Xcode) shows composited regions directly —
a fullscreen layer on the direct path should not flash.

---

## Phase 1 — Spike `presentDrawable:atTime:`

Twenty lines, and it determines the architecture. In the display-link callback, replace:

```objc
    [cb presentDrawable:d];
```

with a target one refresh beyond the prediction, and see whether `presentedTime` follows:

```objc
    double testTarget = u.targetPresentationTimestamp + ifi;
    [cb presentDrawable:d atTime:testTarget];
```

If confirmed `presentedTime` lands on `testTarget`, the call works with the display link and
you can specify presentation time directly. If the frame presents at the original tick
regardless, `atTime:` is being ignored in this configuration and you fall back to tick
arithmetic alone.

**A constraint that applies either way:** `maximumDrawableCount = 2`. A drawable held for a
distant future time occupies a slot in that pool, so the display link cannot acquire another
and will start delivering nil drawables. `atTime:` is therefore usable for short leads — one
to three refreshes — and must not be used to implement a long hold.

---

## Phase 2 — The hybrid design

This is the right architecture whichever way Phase 1 goes, and it is why the tick work is not
wasted:

- **Tick arithmetic decides which tick to wake on.** This keeps you from acquiring a drawable
  and holding it across many refreshes. Only whole-refresh accuracy is needed here — you just
  have to pick the right tick, which needs to be right to within half a frame.
- **`presentDrawable:atTime:` places the frame within that tick**, if Phase 1 shows it works.
  This is what removes the accuracy burden from the lag estimate: you *specify* the time
  rather than *predicting* it, and `presentedTime` becomes a confirmation rather than a
  correction.

If Phase 1 fails, keep the tick selection and present normally; the lag residual (Phase 4)
then has to carry the sub-refresh accuracy on its own.

### 2.1 Record the time↔tick map on every tick

Today `targetPresentationTimestamp` is only read when a frame is accepted
(`PsychMetalCore.mm:121`); when nothing is pending the callback returns at line 110 without
recording anything. After any deliberate frame hold you have no anchor to map against.

Add a static:

```objc
static double lastTickTime;        // targetPresentationTimestamp of tick `ticks`
```

No separate index is needed — it would always equal `ticks`. Use `lastTickTime > 0` as the
"have we seen a tick" flag. In the callback, immediately after `ticks++` and **before** the
early return:

```objc
    ticks++;
    lastTickTime = u.targetPresentationTimestamp;
    pthread_cond_broadcast(&cond);      // lets a first Flip waiting for an anchor proceed
    if (pendingBuffer < 0 || ticks < pendingTargetTick) {
        pthread_mutex_unlock(&lock);
        return;
    }
```

Reset `lastTickTime = 0;` in `openCore` alongside the other counters.

### 2.2 Invert the map

Caller holds `lock`. Returns a *signed* delta so the caller can tell "three ticks ahead" from
"you asked for a time that already passed."

```objc
static int64_t tickDeltaForTime(double when) {
    double offset = lagEstimateFrames * ifi + lagResidual;
    double raw = (when - lastTickTime - offset) / ifi;
    if (!isfinite(raw))
        return 1;
    double k = ceil(raw - 1e-6);              // 1 us guard against FP noise
    if (k >  1e6) k =  1e6;
    if (k < -1e6) k = -1e6;
    return (int64_t)k;
}
```

`ceil` gives PTB's "first refresh at or after `when`" semantics; combined with the
conventional `- 0.5 * ifi` in the caller's deadline it lands on the intended refresh with half
a frame of margin either side.

### 2.3 Extend `enqueue`

Signature becomes `static uint64_t enqueue(int b, double when, bool haveWhen);`. Add
`double requestedTime;` to `Record`. Replace the scheduling block (lines 679–683):

```objc
    uint64_t earliest = ticks + 1;
    uint64_t requested;
    r->requestedTime = haveWhen ? when : NAN;

    if (haveWhen) {
        double anchorDeadline = CACurrentMediaTime() + 2.0;
        while (lastTickTime <= 0)
            if (waitRelative(anchorDeadline) == ETIMEDOUT) {
                pthread_mutex_unlock(&lock);
                fail("No display-link tick observed; cannot schedule a presentation time.");
            }
        int64_t desired = (int64_t)ticks + tickDeltaForTime(when);
        requested = (desired < (int64_t)earliest) ? earliest : (uint64_t)desired;
        r->missedTicks = (desired < (int64_t)earliest)
                       ? (uint64_t)((int64_t)earliest - desired) : 0;
    } else {
        uint64_t cadence = lastTargetTick ? lastTargetTick + 1 : earliest;
        requested = (cadence > earliest) ? cadence : earliest;
        r->slipTicks = (earliest > cadence) ? earliest - cadence : 0;
        r->missedTicks = 0;      // no declared target: nothing to miss
    }

    pendingTargetTick = requested;
    lastTargetTick = pendingTargetTick;
```

The no-`when` branch changes deliberately. In 0.1.1 it reports `pendingTargetTick - requested`
as a miss, which **false-positives on every intentional frame hold** — hold a frame for ten
refreshes and `Missed` comes back at ~167 ms with nothing wrong. Without a declared target
there is no deadline, so the honest value is zero. The cadence heuristic stays, renamed to
`slipTicks` and documented as "ticks by which submission fell behind a one-per-refresh
cadence; expected to be nonzero whenever a frame is held deliberately."

### 2.4 Carry `when` into the present call

If Phase 1 succeeded, pass the requested time through to the callback (store it on the
`Record`, read it back under the lock when the frame is accepted) and use:

```objc
    if (isfinite(requestedTime) && requestedTime > CACurrentMediaTime())
        [cb presentDrawable:d atTime:requestedTime];
    else
        [cb presentDrawable:d];
```

### 2.5 Make the timeouts `when`-aware

Three fixed two-second deadlines assume no wait is ever legitimately long.

- `waitScheduled` — take an absolute deadline parameter instead of computing one internally.
- `enqueue`'s pending-slot wait (line 666) and `waitBuffer` (line 700) — extend to
  `max(now + 2.0, when + 2.0)`. Hoist the computed deadline into a file-scope
  `currentDeadline` set at the top of `enqueue` rather than plumbing `when` through both.

---

## Phase 3 — `mexFunction` and `PsychMetal.m`

**`Queue`:**

```objc
if (cmd(prhs[0], "Queue")) {
    if ((nrhs != 2 && nrhs != 3) || nlhs != 1)
        fail("Queue needs a buffer index and an optional presentation time.");
    int b = (int)unsignedScalar(prhs[1], "buffer index", 1);
    bool haveWhen = (nrhs == 3);
    double when = haveWhen ? scalar(prhs[2], "presentation time") : 0.0;
    plhs[0] = mxCreateDoubleScalar(enqueue(b, when, haveWhen));
    return;
}
```

**`WaitScheduled`:**

```objc
if (cmd(prhs[0], "WaitScheduled")) {
    if ((nrhs != 2 && nrhs != 3) || nlhs != 1)
        fail("WaitScheduled needs a token and an optional presentation time.");
    uint64_t token = unsignedScalar(prhs[1], "frame token", UINT64_MAX);
    double timeoutAt = CACurrentMediaTime() + 2.0;
    if (nrhs == 3) {
        double when = scalar(prhs[2], "presentation time");
        if (when + 2.0 > timeoutAt) timeoutAt = when + 2.0;
    }
    Record r = waitScheduled(token, timeoutAt);
    plhs[0] = mxCreateDoubleMatrix(1, 4, mxREAL);
    double *v = mxGetPr(plhs[0]);
    v[0] = r.projected;
    v[1] = r.scheduled ? 0 : 2;
    v[2] = (double)r.missedTicks;
    v[3] = r.requestedTime;
    return;
}
```

`historyMatrix` grows from 11 to 15 columns: `requestedTime`, `slipTicks`, `renderDeadline`,
and the `glSyncMs` column you already have. Update the width and the reader.

**`Flip` in `PsychMetal.m`:**

```matlab
  assert(numel(varargin) <= 2, ...
      'PsychMetal(''Flip'') supports PsychMetal(''Flip'', w [, when]).');
  haveWhen = numel(varargin) == 2 && ~isempty(varargin{2});
  if haveWhen
   when = double(varargin{2});
   assert(isnumeric(varargin{2}) && isscalar(when) && isfinite(when), ...
       '''when'' must be a finite real scalar in GetSecs time.');
  end
  Screen('DrawingFinished', S.buffer);
  tf = GetSecs;
  if haveWhen
   token = PsychMetalCore('Queue', S.current - 1, when);
  else
   token = PsychMetalCore('Queue', S.current - 1);
  end
  S.lastQueueMs = (GetSecs - tf) * 1000;
  S.current = 3 - S.current;
  if haveWhen
   raw = PsychMetalCore('WaitScheduled', token, when);
  else
   raw = PsychMetalCore('WaitScheduled', token);
  end
  flipReturn = GetSecs;
  S.lastFlipMs = (flipReturn - tf) * 1000;
  % PTB convention: Missed is negative when the deadline was met, positive when late.
  % Without a declared deadline there is nothing to miss, so report zero.
  if haveWhen, missed = raw(1) - when; else, missed = 0; end
  if raw(2) ~= 0, missed = NaN; end
  varargout = num2cell([raw(1), raw(1), flipReturn, missed, -1]);
```

This drops 0.1.1's tick-quantized `raw(3) * S.ifi` in favour of a continuous `projected - when`
— which is what `Screen('Flip')` actually returns, and is not rounded to whole refreshes.
`raw(3)` remains available for `Diagnostic`.

**`Diagnostic`:** add `requestedTime`, `slipTicks`, `renderDeadline`, `renderBudgetMs`, and
`scheduledLatenessMs = (projected - requestedTime) * 1000` for rows where `requestedTime` is
finite. That last column is the direct answer to "did `when` do what I asked."

---

## Phase 4 — Sub-refresh lag correction

Needed on its own merits for the returned timestamps, and load-bearing for scheduling only if
Phase 1 failed. The integer estimator is quantized to whole refreshes and clamped to 0–3, so a
true offset of 1.4 refreshes latches to 1 and leaves a fixed ~6.7 ms error.

```objc
#define LAGWIN 64
static double lagResidual;
static double lagSamples[LAGWIN];
static int lagSampleCount, lagSampleIndex;
static bool lagCalibrated;

static double medianOf(const double *src, int n) {
    double tmp[LAGWIN];
    memcpy(tmp, src, (size_t)n * sizeof(double));
    for (int i = 1; i < n; i++) {            // insertion sort; n <= 64
        double v = tmp[i];
        int j = i - 1;
        while (j >= 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j--; }
        tmp[j + 1] = v;
    }
    return (n & 1) ? tmp[n / 2] : 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
}
```

In the presented handler, replacing lines 192–204. Note the ring must be **reset whenever the
integer estimate changes**, because old samples were measured against a different frame count:

```objc
    int observed = (int)llround((pt - q->rawTarget) / ifi);
    if (observed < 0) observed = 0;
    if (observed > 3) observed = 3;
    if (observed == lagCandidateFrames) lagCandidateCount++;
    else { lagCandidateFrames = observed; lagCandidateCount = 1; }
    if (lagCandidateCount >= 3 && lagEstimateFrames != lagCandidateFrames) {
        lagEstimateFrames = lagCandidateFrames;
        lagSampleCount = lagSampleIndex = 0;
        lagResidual = 0;
        lagCalibrated = false;
    }
    double residual = (pt - q->rawTarget) - lagEstimateFrames * ifi;
    if (fabs(residual) < ifi) {                // reject frames that clearly slipped
        lagSamples[lagSampleIndex] = residual;
        lagSampleIndex = (lagSampleIndex + 1) % LAGWIN;
        if (lagSampleCount < LAGWIN) lagSampleCount++;
        if (lagSampleCount >= 16) {
            lagResidual = medianOf(lagSamples, lagSampleCount);
            lagCalibrated = true;
        }
    }
```

Apply at line 122: `r->projected = r->rawTarget + lagEstimateFrames * ifi + lagResidual;`

Expose `summary.calibratedResidualMs` and `summary.calibrated`. A false `calibrated` means the
returned timestamps are still uncorrected — that is what the warmup is for, and users should
see it rather than infer it. Measure `median(diag.targetErrorMs)` before and after; if it moves
from milliseconds to near zero, that is the headline number for this release.

---

## Phase 5 — Correct the drop reporting

Per Apple's documentation, `presentedTime == 0` means the frame was dropped. Status 1 is
currently described as inconclusive in both the README and the `Diagnostic?` help.

- Relabel status 1 from "Apple returned zero" to "frame dropped (presentedTime == 0)".
- Report `summary.missingPresentedTimes` as a drop count, and surface it in the demo output
  next to the confirmed count.
- Remove the README sentence claiming a missing confirmation "is not by itself evidence that
  the physical frame was missed."

---

## Tests

Add `PsychMetalWhenTest.m`.

| Case | Call | Expected |
| --- | --- | --- |
| Every refresh | `Flip(w, vbl + 0.5*ifi)` × 300 | confirmed intervals ≈ `ifi`; `missed < 0` throughout |
| Every 2nd, 3rd, 4th | `Flip(w, vbl + (n-0.5)*ifi)` × 200 each | intervals ≈ `n*ifi`; zero `gaps ~= n` |
| Deadline in the past | `Flip(w, GetSecs - 0.1)` | presents next tick; `missed > 0`; no error |
| Long hold | `Flip(w, vbl + 29.5*ifi)` | interval ≈ `30*ifi`; `missed < 0`; `slipTicks` may be nonzero, `Missed` must not be |
| Far future | `Flip(w, GetSecs + 3)` | blocks ~3 s and presents; must not hit a timeout |
| No `when` | `Flip(w)` × 300 | unchanged from 0.1.1; `missed == 0` |

The long-hold case is the regression test for the 0.1.1 false positive; the far-future case is
the regression test for the timeout changes. Assert
`abs(median(diag.scheduledLatenessMs)) < 0.25 * ifi * 1000` on the scheduled runs — if that
fails, the time↔tick map has a bias.

---

## Documentation

- `Flip?`: `when`, its `GetSecs` timebase, the `(n - 0.5) * ifi` idiom, `Missed` negative when met.
- `Diagnostic?`: `requestedTime`, `slipTicks`, `renderDeadline`, `renderBudgetMs`,
  `scheduledLatenessMs`, `summary.calibratedResidualMs`, `summary.calibrated`,
  `summary.preferredFrameLatency`.
- README: move `when` out of "not implemented"; note `waitframes` is expressed through `when`;
  state the timebase check; correct the dropped-frame language; replace the Game Mode
  implication with the `LSApplicationCategoryType` caveat; record whatever Phase 0.4 finds
  about compositor bypass.
- CHANGELOG 0.2.0, bump `PsychMetal('Version')` and `VERSION`.

---

## What this still does not do

`when` schedules **one** frame ahead. `enqueue` blocks while `pendingBuffer >= 0` and there are
two IOSurfaces, so pipeline depth is one queued frame plus one being drawn. Precomputing a
burst and handing it off needs an N-surface pool, a pending ring instead of the single slot,
and an explicit buffer-reclaim API — and is additionally bounded by `maximumDrawableCount`.
The tick scheduling built here is the foundation for that, not a substitute.

---

## Commit order

1. **Phase 0** in full. Merge it, run it on hardware, and read the results before writing any
   `when` code — 0.4 in particular may change what you build.
2. **Phase 1** spike. Throwaway commit; record the answer.
3. **Phase 4** (lag residual) on its own, with `targetErrorMs` measured before and after.
4. **Phase 5** (drop reporting) — independent, small.
5. **Phases 2 and 3** — the `when` change proper.
6. Tests, then documentation.

Phases 4 and 5 are deliberately ahead of the `when` work: both change what the existing
diagnostics mean, and you want those effects measured in isolation before `when` starts
depending on them.

---

## References

- [CAMetalDisplayLink.Update](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update)
- [CAMetalDisplayLink.preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency)
- [MTLCommandBuffer.present(_:atTime:)](https://developer.apple.com/documentation/metal/mtlcommandbuffer/present(_:attime:))
- [MTLDrawable.presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
