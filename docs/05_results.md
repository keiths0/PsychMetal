# PsychMetal — measurements, 0.3.1 and 0.4.0

> **Spans two releases.** Sections 1 to 9e were measured against 0.3.1, which
> still had the OpenGL interop path and the `CAMetalDisplayLink` presentation
> mode. Both were removed in 0.4.0. Sections that measured a mechanism which no
> longer exists are marked where they begin; they are kept because they are the
> evidence that justified removing it, not because they describe the library.

All figures from a MacBook Air (M4, 15-inch), internal display 2880 × 1864,
macOS 27.0 beta, GNU Octave 11.3 with Psychtoolbox 3.0.22, direct presentation mode
unless stated otherwise. Nominal refresh 60 Hz; measured 59.99991 Hz.

> **On the OS version, because three sources disagree.** The machine is macOS
> 27.0 beta, which is what `NSProcessInfo` reports and what
> `PsychMetal('Diagnostic')` therefore returns in `macOSVersion`. Psychtoolbox
> reported 28 and the build prefix reads 26A, and an earlier revision of these
> documents took Psychtoolbox's number and said 28 throughout. It was wrong.
> Every figure here was measured on a **beta** OS, which is a caveat on all of
> them and not a footnote: a released 27.0 may schedule differently.

Every number here is a software timestamp derived from `MTLDrawable.presentedTime`.
None of it is a photodiode measurement of light onset. See "Open question".

Sections 1 to 5 and 7 were measured under 0.3.0, in a scaled display mode
(3420 × 2214 framebuffer) and with AppKit managed fullscreen. Section 6 and
section 8 establish that neither of those affects the timing, so the figures
stand; but both differ from what 0.3.1 does.

AppKit managed fullscreen and Game Mode were **removed** in 0.3.1 — the first
because it cannot position correctly on a notched display (section 9) and gave
identical timing, the second because it required the first and did nothing in
direct presentation mode. Sections 2 and 3 are therefore a record of finished
experiments, not of behaviour the current code can reproduce.

---

## 1. Presentation is frame-accurate

Direct mode, one presentation per refresh, 300 measured frames after warm-up:

| | |
| --- | --- |
| Confirmed presentations | 300 / 300 |
| Skipped refreshes | 0 |
| Interval median / p99 | 16.666708 / 16.666792 ms |
| Target prediction error, median / max-abs | 0.025 / 0.107 ms |
| Confirmation delay (presentedTime → handler) | 0.48 ms |

Apple Silicon's mach timebase is 24 MHz, 41.667 ns per tick. Converting the
intervals:

- median 16.666708 ms = **400 001 ticks**
- p99 = max 16.666792 ms = **400 003 ticks**
- nominal 1/60 = 400 000 ticks exactly

Total spread across 300 frames is two timebase ticks. That the intervals are
*not* exactly 400 000 is the evidence that `presentedTime` is a hardware-derived
timestamp rather than a value synthesised from the nominal mode.

### The refresh is 1.75 ppm from nominal, and that is a statement about two clocks

A least-squares fit of `presentedTime` against frame index over ~590 frames
gives **59.999894, 59.999895, 59.999896 Hz** in three consecutive runs — a
between-run scatter of **0.043 ppm** against an offset from nominal of
**−1.750 ppm**. The measurement is solid: 40:1 against its own repeatability.

But it is not "the display is not 60 Hz." It is the display's oscillator measured
in units of the CPU's oscillator, and the two disagree by 1.75 ppm. Nothing
inside the machine can say which is off, and a display crystal within 2 ppm of
nominal is a good one.

Accumulated error: **6.3 ms per hour**. That matters only for a paradigm that
computes elapsed time as a frame count times the nominal 16.666667 ms while
synchronising against an external recording clock. The remedy is to use the
returned timestamps rather than a nominal constant, which one would do anyway.

### How long the warm-up must be

The warm-up exists to measure this period and the grid's phase anchor. The
anchor needs one confirmed presentation, so the period fit sets the length.
Fitting prefixes of a 600-frame run and comparing each against the full fit
(`PsychMetalWarmupLength`):

| Frames | Seconds | Error | Per hour |
| --- | --- | --- | --- |
| 15 | 0.25 | 11.7 ppm | 42 ms |
| 30 | 0.50 | 3.04 | 11 ms |
| 60 | 1.00 | 0.744 | 2.7 ms |
| **90** | **1.50** | **0.322** | **1.2 ms** |
| 120 | 2.00 | 0.073 | 0.26 ms |
| 300 | 5.00 | 0.036 | 0.13 ms |

**90 to 120 frames is the right warm-up** for roughly 1 ms/hour, which is what
the tests already use. Below 120 the error falls as N^1.5, as counting
statistics predict; past 120 it flattens, because the fit is then averaging over
real drift rather than reducing noise. Sampling to 300 frames buys a factor of
two for two and a half extra seconds and is not worth it.

---

## 2. `CAMetalDisplayLink.preferredFrameLatency` has no effect

> **The mechanism measured here was removed in 0.4.0**, and this is why: the
> property does nothing, so the `frameLatency` argument that set it was
> removed from `OpenWindow` too. The display link path went with it.

Apple documents the property as "the amount of time, in frames, your app requests
to render a frame", accepting only 1.0 and 2.0. Measured scheduling horizon
(display-link callback → predicted presentation), 600 frames per configuration:

| Bundle | Requested latency | Max drawables | Horizon |
| --- | --- | --- | --- |
| Standard | 1.0 | 2 | 49.922 ms (2.995 refreshes) |
| Standard | 1.0 | 3 | 49.946 ms (2.997) |
| Standard | 2.0 | 2 | 49.942 ms (2.997) |
| Standard | 2.0 | 3 | 49.943 ms (2.997) |
| Game Mode | 1.0 | 2 | 33.28 ms (1.997) |
| Game Mode | 2.0 | 2 | 33.30 ms (1.998) |

The property reads back the assigned value correctly in every case. Behaviour
does not change. `maximumDrawableCount` 2 versus 3 also produced no measurable
difference in the display-link path.

Requesting 2.0 under Game Mode yields **one** refresh of latency — less than
requested. This is therefore not the documented case of the system needing
additional time; the requested value is ignored in both directions.

**Consequence for the API.** `frameLatency` was removed from `OpenWindow` in
0.3.1. A parameter that provably changes nothing is worse than no parameter: it
invites a user to tune it and then to attribute a difference to it. The finding
stands as a finding, and the Feedback Assistant reproducer is the standalone
`fblatency.m`, which needs no part of PsychMetal. `PsychMetalLatencySweepTest`
went with it, since its 2×2 was this parameter crossed with drawable count.

---

## 3. Game Mode moves the display link, not the pipeline

> **Measured against a path that no longer exists.** Presentation is inline on
> the calling thread as of 0.4.0; there is no display link for Game Mode to
> move. Kept as the record of what Game Mode did and did not do.

ABA design, 2400 frames per arm:

| Run | Scheduling horizon | Confirmed | Skips |
| --- | --- | --- | --- |
| Baseline 1 | 2.9949 refreshes (49.922 ms) | 2400/2400 | 0 |
| Game Mode | 1.9975 refreshes (33.299 ms) | 2399/2400 | 0 |
| Baseline 2 | 2.9963 refreshes (49.947 ms) | 2400/2400 | 0 |

Baselines differ by 0.025 ms; the effect is 16.636 ms, within 0.03 ms of one full
refresh. One frame in the Game Mode arm returned `presentedTime == 0`, which
Apple documents as "not presented, or its associated frame was dropped"; it is
reported as one unclassified unconfirmed result rather than a confirmed drop.

Decomposing against Apple's `targetTimestamp` (the documented rendering
deadline):

| | Render budget | Post-deadline | Total |
| --- | --- | --- | --- |
| Baseline | 16.527 ms (1.0) | 33.395 ms (2.0) | 3.0 |
| Game Mode | 16.570 ms (1.0) | 16.729 ms (1.0) | 2.0 |

The render budget is unchanged. Exactly one refresh disappears from the interval
between the rendering deadline and predicted presentation.

**But in direct mode Game Mode does nothing:**

| | GPU end → presented | Total lead |
| --- | --- | --- |
| CLI Octave, direct | 1.658 refreshes | 1.764 |
| Game Mode bundle, direct | 1.655 | 1.756 |

So Game Mode reduces `CAMetalDisplayLink`'s own scheduling depth. It does not
touch the underlying presentation pipeline.

Note also that the Game Mode baseline used a properly bundled Cocoa GUI host with
a real `CFBundleIdentifier`, and sat at 2.995 refreshes — indistinguishable from
the original bundle-less CLI run at 2.996. **Bundle identity and application
lifecycle account for none of the effect.**

---

## 4. The presentation pipeline is invariant

Interval from GPU completion to reported presentation, direct mode:

| Configuration | GPU end → presented |
| --- | --- |
| CLI Octave, `presentDrawable:` | 1.658 refreshes |
| Game Mode bundle, `presentDrawable:` | 1.655 |
| CLI Octave, `presentsWithTransaction` | 1.661 |

Three presentation mechanisms, two policy states, spread of 0.006 refreshes.
Nothing exposed by Metal or Core Animation moves it: not the display link, not
direct acquire/present, not `presentsWithTransaction`, not Game Mode, not
`preferredFrameLatency`, not `maximumDrawableCount`.

### It is a scheduling wait, not accounting

Same code, `displaySyncEnabled` the only variable:

| | GPU end → presented | Loop interval |
| --- | --- | --- |
| vsync ON | 27.563 ms (1.654 refreshes) | 33.33 ms |
| vsync OFF | **2.582 ms (0.155 refreshes)** | 7.13 ms |

A 25 ms difference. Two consequences:

1. The frame is complete and available 2.6 ms after the GPU stops. The 27.6 ms
   with vsync on is the frame waiting, not work being done.
2. `presentedTime` is **not** stamped at the end of scan-out. If it were,
   vsync-off would still have reported ~16 ms, because a scan-out takes a full
   frame regardless of when presentation was granted.

---

## 5. The present call is punctual; the swap is not

Two-phase path — `PrepareFlip` does the GL fence, `nextDrawable`, encode, commit
and `waitUntilScheduled`; `PresentNow` issues only `[drawable present]`:

| | |
| --- | --- |
| `[drawable present]` duration, median | 0.041 ms |
| p90 | 0.052 ms |
| max | 0.125 ms |

The call is essentially instantaneous. With vsync off and the swap timed against
the measured refresh grid, the resulting phase spread was nevertheless 1.5–2.5 ms
(10th–90th percentile) — no better than the single-phase path.

The call only *posts* a request; the register write happens when the render
server is next scheduled. That cross-process hop carries the variance, and it is
far wider than a vertical blank. **Software vsync is therefore not viable on this
hardware**: no fixed offset keeps the swap inside the blank, so some frames
always tear.

---

## 6. A present call is displayed two boundaries later

Two-phase path, vsync ON, present call swept across the refresh cycle, each call
anchored to a freshly confirmed presentation. Presentation reported as whole
refresh boundaries from that anchor, 40 frames per phase:

| Call phase | Presentation (refreshes from anchor) | Call → presentation |
| --- | --- | --- |
| 0.025 – 0.650 | 4.000 | 27.17 ms falling to 17.25 ms |
| 0.675 – 0.975 | 5.000 | 32.96 ms falling to 28.00 ms |

Presentation is an exact integer boundary at every one of the 39 phases, in
every arm run so far. Calling later within a band does not move the
presentation; it only eats into the wait.

**The floor is 17.245 ms, 1.035 refresh intervals.** One refresh is 16.667 ms,
so the boundary immediately following a present call is always out of reach: a
call issued at the very start of a cycle misses the next boundary by 0.6 ms.

The rule is therefore simple and has no phase dependence:

> A present call issued during cycle N is displayed at the boundary that starts
> cycle N+2.

The band structure in the table is the cycle rollover — calls whose measured
time falls in cycle 2 present at boundary 4, calls in cycle 3 present at
boundary 5 — not a deadline partway through a refresh.

### Correction to an earlier reading

This section previously described "a deadline at phase 0.65, 10.8 ms into the
refresh", and concluded that the extra refresh was a cutoff an application could
in principle meet to achieve 1.0 refreshes. That was wrong. The 0.65 figure is
the phase the sweep *requests*; the phase the call actually lands on is about
0.34 refreshes later, and correcting for that offset the rollover sits on the
cycle boundary. There is no phase at which the next boundary becomes reachable.

The ~0.34-refresh (~5.7 ms) discrepancy between requested and realised call
phase is unexplained and worth chasing separately. It does not affect the
boundary counts, which are measured directly.

### Drawable count does not move the floor

If the application were writing into a slot two refreshes ahead, three buffers
would be needed to reach N+2 and two buffers should reach N+1. Tested directly,
ABA, 40 repeats per phase per arm (`PsychMetalDrawableCompare`):

| | 3 drawables | 2 drawables | 3 drawables again |
| --- | --- | --- | --- |
| Fastest call → present | 17.2455 ms | 17.2432 ms | 17.2503 ms |
| In refresh intervals | 1.0347 | 1.0346 | 1.0350 |
| Cutoff phase | 0.650 | 0.650 | 0.625 |

Effect of dropping to two drawables: **−0.0047 ms**, against a baseline drift
between the two 3-drawable arms of **0.0048 ms**. Every arm produced exact
integer boundaries at every phase.

So the one-refresh lead is a property of the compositor, not of the drawable
pool. Buffer count adds queue depth in a continuous loop — one refresh each, see
section 7 — but does not change what a drained pipeline can achieve.

**Caveat.** The 2-drawable arm shows anchor instability between phases 0.675 and
0.875: `call(refr)` goes non-monotonic (3.114, 3.134, 3.145, 3.106, 3.118) and
the median boundary disagrees with the median call-to-present, which happens when
the confirmed anchor is occasionally a frame stale. The 3-drawable repeat arm has
three similar outliers. This does not touch the minimum, which is the statistic
the comparison rests on and which reproduced to 0.005 ms across three arms, but
the per-phase medians in those bands should not be quoted.

---

## 7. Rate and latency trade against each other

Submit-to-presentation, direct mode:

| Configuration | Rate | Submit → presented |
| --- | --- | --- |
| Continuous, naive | 60 Hz | 2.68 refreshes (44.8 ms) |
| Continuous, phase-targeted at 0.55 | 60 Hz | 2.40 refreshes (40.0 ms) |
| Wait for confirmation (one frame in flight) | 30 Hz | 1.68 refreshes (28.0 ms) |
| Drained queue, phase 0.625 | — | 1.04 refreshes (17.3 ms) |

The phase result in section 6 is measured from an *empty* queue. Running
continuously at 60 Hz keeps ~2.4 frames outstanding, and a new present goes
behind them, so phase becomes a marginal correction worth about 4 ms rather than
the 27 ms the isolated measurement suggests.

Input-to-photons for a mouse-tracking stimulus, 300 frames, zero skips in both:

| | Rate | Mouse sample → presented |
| --- | --- | --- |
| Naive loop | 60 Hz | 48.33 ms (2.90 refreshes) |
| Phase-targeted at 0.55 | 60 Hz | 44.34 ms (2.66) |

Each additional drawable costs exactly one refresh of latency at full rate: the
naive path measured 44.5 ms with two drawables and 61.2 ms with three.

---

## 8. Nothing about the window or the display mode moves the floor

Three further attempts to remove the one-refresh lead, each an ABA design with
the middle arm as the manipulation, run after sections 1–7.

### Native versus scaled display mode

Sections 1–7 were measured with the panel in a scaled HiDPI mode: a 3420 × 2214
framebuffer resampled to the 2880 × 1864 panel. A resampling pass between the
IOSurface and the display controller would be an obvious source of a fixed
delay, so the whole latch sweep was repeated at native resolution.

| | Scaled (3420 × 2214) | Native (2880 × 1864) |
| --- | --- | --- |
| Fastest call → present | 17.2455 / 17.2432 / 17.2503 ms | 17.2879 / 17.2595 / 17.2458 ms |

No effect. The resampling pass is not in the path, or costs nothing.

### Managed fullscreen versus captured display

Psychtoolbox's OpenGL path takes CGL exclusive fullscreen with the display
captured, and `PsychWindowGlue.c` says this is done "to exclude the desktop
compositor from interfering". PsychMetal cannot take that path — a `CAMetalLayer`
requires an `NSWindow` — but it can capture the display and raise a borderless
display-sized window to `CGShieldingWindowLevel`, which is as close as a
layer-based backend gets. PTB's own Vulkan backend is excluded from the CGL path
for exactly the same reason; see the `kPsychExternalDisplayMethod` test.

| | Managed | Shielded (captured) | Managed again |
| --- | --- | --- | --- |
| Fastest call → present | 17.3107 ms | 17.0349 ms | 17.0379 ms |
| Display captured | 0 | 1 | 0 |

The adjacent pair is the clean comparison: shielded 17.0349 against the managed
arm run immediately after at 17.0379, a difference of 0.003 ms. Capturing the
display and shielding the window does not change **the latch minimum**.

### Correction: it does change the sustained case, for the better

The table above measures the floor from a *drained* queue. That is not the same
question as what a continuous 60 Hz loop achieves, and the two moved
differently:

| | AppKit fullscreen | Captured + shielded |
| --- | --- | --- |
| Latch minimum, drained queue | 17.038 ms | 17.035 ms |
| **Sustained loop, submit → presented** | **44.5 ms (2.67 refreshes)** | **29.8 ms (1.79)** |
| Skipped refreshes per 300, warmed | 0 | 0 |

Removing AppKit fullscreen took a **full refresh** off sustained
submit-to-presentation at no reliability cost. The latch test could not see this,
and this document previously reported "no difference" on the strength of it. That
was wrong: the conclusion was correct for the statistic measured and was
generalised past what it supported.

An intermediate reading of these runs attributed 1–3 dropped frames per 300 to
the shallower queue. That was a warm-up artifact — see below. Once warm, two
drawables hold 60.000 Hz with zero skips at 1.791 refreshes.

Drawable count under the current windowing, ABA:

| | 2 drawables | 3 drawables | 2 again |
| --- | --- | --- | --- |
| Rate | 58.820 Hz | 60.000 Hz | 60.000 Hz |
| Skipped / 300 | 6 | 0 | 0 |
| Submit → presented | 29.788 ms (1.787) | 46.540 ms (2.792) | 29.852 ms (1.791) |

The third drawable costs **+1.003 refreshes** for no measurable benefit, so two
remains the default. The 6 skips in the first arm are warm-up, not buffer depth:
the identical configuration in the third arm dropped none.

### Sporadic frame drops, cause not established

An earlier draft of this section claimed a session warm-up effect: the first arm
of a run being systematically worst. Five runs supported it. The sixth, with a
discarded warm-up arm added, did not — the warm-up arm dropped nothing and the
first measured arm dropped three. The pattern was over-fitted to a small number
of runs and is retracted.

What is actually observed is sporadic dropping, tallied across every 300-frame
arm run so far:

| Configuration | Skips per arm |
| --- | --- |
| 2 drawables | 1, 1, 3, 6, 0, 0, 3, 0 |
| 3 drawables | 0, 0 |

Five of eight two-drawable arms dropped at least one frame; neither
three-drawable arm did. That is the direction a queue-depth explanation predicts
— more buffering, more tolerance for a late frame — but two arms is not
evidence, and the two-drawable spread of 0 to 6 is wide enough that the
difference could easily be noise.

**This is unresolved and matters**, because it is the difference between a
default that occasionally drops a frame and one that does not. It needs
replication: many repeats of 2 versus 3, counting skips, not another single ABA.
Until then the honest statement is that two drawables sometimes drops frames at
60 Hz, at roughly 0 to 2 percent, and no manipulation tested so far explains it.

Drops are at least detectable rather than silent: each appears in `Diagnostic`
as a confirmed interval longer than one refresh, so an experiment can count them.

A methodological note that survives the retraction: every ABA in this document
places the manipulation in arm 2. If any position effect exists — and the
first-arm data is suggestive even if not conclusive — those comparisons are
biased toward the manipulation. They all reported no effect, so nothing was
manufactured, but the quoted precision is optimistic.

--- | --- | --- | --- |
| Drawable latch (scaled) | 17.288 ms | 17.260 | 17.246 |
| Drawable latch (native) | 17.002 | 17.261 | 17.415 |
| Window mode | 17.311 | 17.035 | 17.038 |
| Capture, skips | 1 | 1 | 3 |
| Drawable rate, skips | 6 | 0 | 0 |

The effect is of the same order as everything being measured. Because the ABA
design puts the manipulation in arm 2 — the position warm-up favours — every
comparison in this document is biased *towards* finding the manipulation
beneficial. All of them reported no effect, so the bias did not manufacture a
result; but a small real effect against the middle arm could have been masked,
and the quoted precision is optimistic.

`PsychMetalRateCompare` now runs a discarded warm-up arm first. The older
comparisons do not, and should be re-run before anything depends on them
quantitatively.

Display capture itself is not the cause of either. ABA on capture alone, window
at `CGShieldingWindowLevel` in all three arms
(`PsychMetalRateCompare(300)`):

| | Capture | No capture | Capture |
| --- | --- | --- | --- |
| Rate | 59.800 Hz | 59.800 Hz | 59.404 Hz |
| Skipped / 300 | 1 | 1 | 3 |
| Submit → presented | 29.768 ms | 29.845 ms | 29.858 ms |

Skip drift between the two capture arms is 2, larger than any effect. Capture
costs nothing and is kept because it is what keeps other windows off the
stimulus.

Dropped frames are detectable rather than silent: each appears in `Diagnostic`
as a confirmed interval longer than one refresh.

Note the first arm sits 0.27 ms above the other two, and the drawable-count run
showed the same monotonic decline (17.288 → 17.260 → 17.246). There is a warm-up
trend across arms within a session, so ABA understates precision here; ABAB
ordering would be better for any further work of this kind.

### Full-panel coverage

Establishing that the shielded window genuinely covers the whole display — see
section 9 — closes the remaining version of this hypothesis. The measurement
above was taken with `windowFrame = 0 0 2880 1864`, the display captured, and
the stimulus reaching the notch region. Still 17.03 ms.

**Summary of everything excluded.** The interval from a present call to
presentation has now survived: display link versus direct present,
`preferredFrameLatency`, `maximumDrawableCount`, `presentsWithTransaction`, Game
Mode, bundle identity and Cocoa lifecycle, scaled versus native display mode,
managed versus captured-and-shielded windowing, and full-panel coverage. Nothing
reachable from an application touches it.

---

## 9. A stimulus position bug, found while chasing the above

AppKit's `toggleFullScreen:` on a display with a notch places the window at
`y = -safeAreaInsets.top`. The size is right and the drawable is right; only the
origin is wrong.

| | Managed | Shielded | Psychtoolbox |
| --- | --- | --- | --- |
| `cgDisplayBounds` | 0 0 2880 1864 | 0 0 2880 1864 | — |
| `screenFrame` | 0 0 2880 1864 | 0 0 2880 1864 | — |
| `safeAreaInsets` (T L B R) | 56 0 0 0 | 56 0 0 0 | — |
| **`windowFrame`** | **0 −57 2880 1864** | **0 0 2880 1864** | — |
| `viewBounds` | 0 0 2880 1864 | 0 0 2880 1864 | — |
| `layerFrame` | 0 0 2880 1864 | 0 0 2880 1864 | — |
| `drawableSize` | 2880 × 1864 | 2880 × 1864 | 2880 × 1864 |
| Screen rect | — | — | 0 0 2880 1864 |

Every rectangle matches the panel except the window origin. The consequence is
that in managed mode every stimulus was displaced 57 pixels downwards and the
bottom 57 rows never appeared. Confirmed visually: the managed arm leaves the
menu bar strip black, the shielded arm and Psychtoolbox both paint it.

Anything referenced to screen centre, or measured in eccentricity, was wrong by
57 pixels in every run before 0.3.1. No timing result is affected — those are
intervals and latencies, which do not depend on where the stimulus sits.

**It cannot be corrected in managed mode.** Moving the window to the display
origin makes AppKit clamp the content view to `visibleFrame`, giving a
2880 × 1807 drawable: the same rows lost, by scaling instead of displacement.
Managed fullscreen offers the correct origin or the full height, not both. This
is presumably why Psychtoolbox never went near AppKit fullscreen.

The captured-display window has neither problem, and in 0.3.1 it is the only
window mode; AppKit fullscreen was removed. `PTBGeometryCompare` prints
the whole chain and checks origins as well as sizes — the first version of that
script compared only heights and reported the managed window as correct, which is
the failure mode this table exists to prevent.

Since the managed arm no longer exists, the table above cannot be regenerated by
the current code. It is kept as the record of why that mode was removed.

---

## 9b. Two drawables cannot sustain 60 Hz from a Metal-only loop

Section 7 records the latency cost of a third drawable. It does not record the
throughput cost of having only two, which is larger and was the cause of every
anomaly below.

With two drawables, `Flip` blocks inside `nextDrawable` until the older drawable
is released, which happens a full presentation later. The loop is therefore
pinned to vsync *inside* `Flip`, leaving about 3.2 ms of a 16.67 ms refresh for
everything else. Loops landing near that boundary are decided by noise.

Five configurations, 300 frames each, two passes per arm:

| Arm | 2 drawables | 3 drawables |
| --- | --- | --- |
| Gaussian | 48.1 Hz, 90 skipped | **60.000, 0** |
| Gaussian + GetMouse | 53.6 Hz, 36 skipped | **60.000, 0** |
| 5 textures | 54.9 Hz, 28 skipped | **60.000, 0** |
| 5 textures + GetMouse | 56.9 Hz, 16 skipped | **60.000, 0** |
| Gaussian, GL interop on | 32.5 Hz, 252 skipped | **60.000, 0** |

Repeat passes of *identical* work disagreed by up to 19 Hz at two drawables and
were exact at three. The wrapper defaulted to two while the mex defaulted to
three; the wrapper now says three.

**This invalidated a chain of earlier conclusions.** Texture pixel format, the
shape instance-buffer ring, OpenGL interop and `GetMouse` were each measured
while the loop sat on the deadline, and each appeared to matter. None was the
cause. In particular the OpenGL interop result — 30.5 Hz on, 51.8 Hz off, which
looked decisive — is an artefact: at three drawables, interop **on** flips in
13.5 ms and holds 60.000 with zero skips. `UseOpenGL` was a way to skip work
that could not affect the image, never a timing control, and there is no interop
left for it to skip: OpenGL was removed entirely in 0.4.0.

Two drawables remain available and are the right choice when input latency
matters more than sustained rate; see the trade in section 7.

Method note: a first version of this analysis compared `Flip` + drawing against
one refresh and reported near-zero headroom everywhere. That is circular. `Flip`
blocks, so it absorbs whatever slack exists and the sum is always about one
refresh whenever the loop keeps up. Only work *outside* `Flip` is informative,
and that is 3.2 ms against 16.67.

---

## 9c. The drawable wait, not the pipeline, was the input latency

Section 7's input-to-photons figures conflated two things. Correcting the
instrumentation separated them, and the answer changed.

`scheduledAt` was stamped when `Flip` begins, five lines *before*
`layer.nextDrawable`, so `presented − scheduledAt` charged the wait for a free
drawable to the compositor. A `committedAt` stamp at `[cb commit]` now gives the
pipeline proper, and the difference is reported as `drawableWaitMs`.

With that separation, 300 frames per arm:

| Arm | dwait | commit→pres | sample→pres | Rate | Skipped |
| --- | --- | --- | --- | --- | --- |
| 3 drawables, sample early | 12.35 ms | 1.971 | 2.948 | 60.000 | 0 |
| 3 drawables, `WaitToDraw` | 12.04 ms | 1.971 | 2.901 | 60.000 | 0 |
| 3 drawables, **prefetch** | **0.11 ms** | 1.732 | **1.960** | **60.000** | **0** |
| 2 drawables, prefetch | 0.14 ms | 1.696 | 1.951 | 30.000 | 299 |

The pipeline was never the problem. Commit→presented is ~1 refresh at two
drawables and ~2 at three, and the frame always reaches the boundary it is aimed
at — nothing is missed. What made a mouse-tracked stimulus feel late was the
loop reading the pointer, then blocking ~12 ms in `nextDrawable`, then
committing a position that had gone stale: 0.942 refreshes from sample to commit
against 0.975 from commit to photons.

The wait is irreducible — two frames cannot share a drawable — but its position
is not. Acquiring the *next* frame's drawable at the end of `Flip` moves the
block before the following sample. Frame time and rate are unchanged; only
staleness goes. That is worth a full refresh.

`WaitToDraw` cannot substitute: it sleeps on a predicted time without taking a
drawable, so the pool is still empty when `Flip` runs. It saved 0.7 ms.

Prefetch requires a spare drawable. At two, holding one leaves nothing to
pipeline against and the rate halves, so `OpenWindow` ties the two together:
three drawables and prefetch, or two and neither.

**This resolved the latency-versus-rate trade rather than choosing a side.**
Two drawables alone gave 1.92 refreshes with 12–30 skips per 300; three alone
gave 60.000/0 at 2.90 refreshes. Three with prefetch gives 1.96 refreshes at
60.000 with zero skips — better latency than two drawables ever achieved, at a
rate two drawables never held. Drawing during refresh N is displayed at N+2.

Caveat: prefetch also moved commit→presented slightly, 1.971 to 1.732 refreshes,
which it should not if it only relocates a wait. Unexplained. Also, the
two-drawable arms varied between sessions (commit→presented 0.975 then 1.464,
rate 54.6 then 41.1) while the three-drawable arms were stable, so the
two-drawable column wants re-measuring in a window of its own before it is
quoted.

---

## 9d. One refresh of the two is composition, and the app cannot decline it

The layer requests everything that makes macOS eligible to promote it to a
hardware plane: `opaque = YES`, `framebufferOnly = YES`, `BGRA8Unorm`,
`colorspace = nil`, no EDR, `CGDisplayCapture`, borderless window at
`CGShieldingWindowLevel`. macOS reports nowhere whether that succeeded, so the
evidence is timing.

Commit → presented, 300 frames per arm, each in its own window, three drawables
with prefetch, measured from `committedAt`:

| Arm | p01 | Median | p99 | Rate |
| --- | --- | --- | --- | --- |
| Scaled 3420×2214, vsync on | 1.710 | 1.751 | 1.843 | 60.000 |
| Scaled 3420×2214, vsync **off** | 0.219 | **0.266** | 0.372 | 484 |
| Native 2880×1864, vsync on | 1.692 | 1.752 | 1.856 | 60.000 |
| Native 2880×1864, vsync **off** | 0.187 | **0.246** | 0.322 | 527 |

**The panel fitter costs nothing.** Native minus scaled is +0.002 refreshes.
Section 8 reached the same conclusion at two drawables with the old lead stamp,
and was right; the re-measurement was done because that regime produced four
wrong null results elsewhere, not because this one looked suspect.

**The data path is fast.** With vsync off, a committed frame reaches the display
in a quarter of a refresh and the loop sustains 484–527 presentations/s. Nothing
here is throughput-bound, and the 1.75 refreshes under vsync is a scheduling
wait, not transfer or composition *work*.

**Two boundaries, not one.** If the only cost were waiting for the next vblank,
commit → presented would be uniform on 0 to 1 refresh: p01 near 0, p99 near 1,
median near 0.5. It is instead pinned at 1.75 with a p01-to-p99 spread of 0.13.
A phase-locked loop committing at a fixed point in the cycle is being presented
two boundaries later, every time.

The first boundary is unavoidable — a frame cannot be presented into the refresh
already being scanned out. The second is composition: WindowServer takes the
frame at one vblank, composites during that refresh, and scans it out at the
next. It is worth **one refresh, 16.7 ms**, and it is the difference between the
N+2 this achieves and the N+1 the hardware demonstrably can do.

Nothing exposed to the application moves it. Across sections 2, 3, 4, 8 and this
one: display link, `preferredFrameLatency`, `maximumDrawableCount`,
`presentDrawable:` versus `presentsWithTransaction`, Game Mode, bundle identity,
scaled versus native resolution, managed versus captured windowing, and
full-panel coverage. The floor is Apple's to remove.

---

## 9e. Scheduled presentation: the defect was ours, and the fix was to stop

`Flip(w, when)` put a request exactly four refreshes ahead one refresh late, on
97 to 99% of frames, while every other cadence was exact. It is fixed, and the
fix was to delete the scheduling rather than repair it.

### What it looked like

Deterministic, and immune to everything:

| Ruled out | How |
| --- | --- |
| A cadence threshold | gaps 5 to 8 exact while 4 failed |
| The deferred submission branch | gaps 4 to 8 all take it; only 4 failed |
| The commit lead time | varied from −1.19 to −3.69 refreshes across mechanisms with no effect |
| The rhythm | 99% late inside a randomised cadence sequence |
| The history | 83 to 100% late after every possible preceding gap |
| The prediction | `projected` 0.000 in every arm of every run |
| Noise | zero spread, four independent runs |

An earlier, messier form varied between runs — different cadences affected each
time. That was `presentDrawable:atTime:` being handed a target that is itself a
grid point, and therefore the instant a latch closes, so the outcome turned on a
sub-microsecond phase fixed when the window opened.

### What it was

We were scheduling at all. Three mechanisms were measured, two of them ours:

| What decides the boundary | Gap 4 late |
| --- | --- |
| Our commit timing; plain present | 99% |
| Apple, after we sleep to within four refreshes | 96% |
| **Apple alone; commit immediately, no sleep** | **1%** |

The third across cadences 1 to 12, 120 frames each: **0 to 1% late, spread
0.000, in three consecutive sweeps**.

An intermediate version — Apple's scheduler with nothing bounding how far ahead
the loop committed — gave one clean sweep and then a repeat with cadence six at
42%. That was pool exhaustion, not scheduling: with nothing to stop it the loop
committed frames up to 15.65 refreshes early and held their drawables the whole
time. Bounding occupancy fixed it, and the three sweeps above are after that.

**The returned timestamp was fixed by the same change.** Projected minus
confirmed went from 120 frames of 510 at −1 refresh (23.6%) to 1 of 510 (0.2%).
The scheduling defect and the prediction defect were the same bug seen from two
ends: a prediction derived from a commit moment we chose badly.

`presentDrawable:atTime:` knows the display's schedule and every frame queued
against it. Our sleep, our fitted grid and our commit-lead arithmetic were all
attempts to compute something the system already knew, and the four-refresh case
is where our version and the truth disagreed. No property of the pipeline was
ever going to explain it, which is why five candidate causes fell without
progress.

### The one real constraint

With no sleep the loop runs ahead as far as the drawable pool allows. At an
eight-refresh cadence that measured a commit 15.65 refreshes before the target
and 60% of frames late — pool exhaustion, not scheduling. Capping **frames in
flight** at two, rather than bounding time, fixes it at every cadence: two
outstanding frames always leave a third drawable free, whatever the spacing.

`Flip` now commits the frame and calls `presentDrawable:atTime:`. There is no
mode switch and no other path. Reproducing the old defect means reverting the
commit, which is the right amount of friction for something this misleading.

Two bounds remain, both about drawable occupancy rather than timing: at most two
frames in flight, and targets more than fifteen refreshes out sleep until twelve
refreshes before the target. Without the second, a three-second target held a
drawable for three seconds and `PsychMetalWhenTest`'s far-future case stopped
blocking — removing the scheduling removed that guard with it. Fifteen refreshes
is far outside the range where cadence was measured, so the guard cannot place a
frame; that distinction is what the deleted mechanisms got wrong.

---

## 9f. The 0.4.0 removals did not fix the sporadic late presentations

Two consecutive runs of `PsychMetalWhenTest` after OpenGL and the
CAMetalDisplayLink path were removed:

| | run 1 | run 2 | 0.3.1 baseline |
| --- | --- | --- | --- |
| Late scheduled presentations | 0 of 508 (0.00%) | 2 of 508 (0.39%) | 1 to 4 (0.2 to 0.8%) |
| Longest consecutive late run | 0 | 2 | 1 to 3 |
| Projected minus confirmed, max | +0.000 | +1.000 refreshes | up to 1 refresh |
| Frames exactly one refresh early | 0.0% | 0.2% | 0.2% |

**Run 1 was luck, and this section originally said so before run 2 confirmed
it.** At the baseline rate of about 0.4%, the chance of seeing no late frames in
508 is roughly 13%, so a single clean run was never evidence of a change. Run 2
lands on 0.39%: indistinguishable from 0.3.1.

The sporadic lateness is therefore **unchanged and still not understood**. It
survives the removal of OpenGL, the IOSurface pair, the display-link path, the
lag calibration and the timebase correction, which eliminates all of those as
causes and leaves the list of candidates shorter but not empty.

In run 2 the failure was rows 427 to 429: a gap-4 request presented one refresh
late, and the following row absorbing the displacement. That is the cascade
described in section 9e, at its reduced two-row length rather than the original
four.

WHAT THIS SECTION IS FOR. Not the result — the result is "no change". It is here
because a single clean run was allowed to look like a fix for the length of one
paragraph, and the correction is cheaper to read than to rediscover.

---

## 10. Recommended configurations

**Both loops — the default.** Direct mode, `waitForConfirm` false, three
drawables with prefetch, `when` for scheduling when the sequence is known in
advance. 60 Hz, zero drops, intervals stable to 84 ns, `Flip` returning a
predicted timestamp accurate to 24 µs, and 1.96 refreshes from an input sample
to photons. Drawing during refresh N is displayed at N+2.

There is no longer a configuration choice to make between open and closed loop.
The trade that used to force one — two drawables for latency against three for
reliability — was an artefact of waiting for a drawable *after* reading input.
Prefetch removes it, and the demos measure 1.962 to 1.966 refreshes at 60.000/s
with no skips.

**When to depart from the default.** Pass two drawables only if something about
a particular display or driver makes prefetch misbehave; expect roughly 1.9
refreshes and dropped frames. Prefetch at two drawables is not a valid
combination and warns.

**Set the background colour at `OpenWindow`** rather than drawing a field every
frame. It is the render pass load action, so the field costs nothing; a
full-screen `FillRect` is an instanced quad drawn over an already-cleared frame.
(Through 0.3.1 this only mattered with `UseOpenGL` off, since the interop blit
wrote every pixel and the clear was skipped. There is no interop path now, so it
always applies.)

`NextPhase`, `PrepareFlip` and `PresentNow` are **measurement instruments**, not
a recommended stimulus path. The earlier advice here — run at 60 Hz and present
the responding frame at phase 0.625 — rested on the drained-queue row of section
7, which is an isolated measurement from an empty queue. Under a continuously
running loop the phase correction is worth about 4 ms, not the 27 ms that row
suggests, and no closed-loop paradigm has been measured end to end. Treat the
section 7 table as the evidence and pick from it deliberately.

---

## 11. Feedback Assistant items

**1 — Bug.** `CAMetalDisplayLink.preferredFrameLatency` has no effect on
presentation scheduling. Section 2. The property accepts and reads back 1.0 and
2.0 and changes nothing across eight configurations and two policy states;
requesting 2.0 under Game Mode yields one refresh, i.e. less than requested, so
this is not the documented "system needs more time" case.

**2 — Bug or enhancement.** A fullscreen, opaque, `framebufferOnly` `CAMetalLayer`
whose `drawableSize` exactly matches the display mode reports `presentedTime`
1.751 refresh intervals after `[commandBuffer commit]` with
`displaySyncEnabled = YES`, and **0.266** with it set to `NO`. Sections 4, 6
and 9d.

Measured from the commit itself, not from the start of the flip call: an earlier
stamp taken before `nextDrawable` conflated this with drawable-pool
backpressure. 300 frames per arm, three drawables with one held in reserve so
the loop never blocks acquiring one, 60.000 presentations/s with zero skipped
intervals.

The distribution is the point. Were the only cost a wait for the next boundary,
commit → presented would be uniform on 0 to 1 refresh: p01 near 0, p99 near 1.
It is instead p01 1.710, median 1.751, p99 1.843 — a spread of 0.13 refreshes
about a value of 1.75. A phase-locked loop committing at a fixed point in the
cycle is presented **two** boundaries later, every frame. One boundary is
unavoidable; the second is not accounted for by anything the application can
observe or control.

With `displaySyncEnabled = NO` the same frames reach the display in a quarter of
a refresh at 484 to 527 presentations/s, so neither transfer nor composition
*work* is the cost. The frame is complete and idle for a full refresh before it
is shown.

A present call issued during refresh cycle N is displayed at the boundary
starting cycle N+2, at every phase tested; the floor is 1.035 refresh intervals,
so the immediately following boundary is never reachable. `[drawable present]`
itself is punctual to 125 µs worst case.

The following were each tested with an ABA design and none of them moves it:
`preferredFrameLatency`, `maximumDrawableCount` (2 versus 3: 17.2432 and
17.2455 ms), `presentsWithTransaction`, Game Mode, bundle identity and
application lifecycle, AppKit managed fullscreen versus a captured display with
the window at `CGShieldingWindowLevel` (17.0349 versus 17.0379 ms), and a scaled
versus native display mode — the last re-measured under section 9d's conditions
at 1.751 versus 1.752 refreshes, so the panel fitter is not responsible. The layer is opaque and `framebufferOnly`, its
`drawableSize` exactly matches the display mode, and the window covers the panel
exactly at `0 0 2880 1864`.

So the frame is complete, the application holds the buffer, the compositor is
shielded out, and the layer is in every documented configuration for direct
scanout — and it still will not go on the next boundary. Request: allow a
completed frame to be armed for the next refresh boundary rather than the one
after it, or document the deadline that makes this impossible.

**3 — Enhancement.** No API exists to query the frame latency actually granted.
Reading `preferredFrameLatency` returns the requested value. Applications with
hard presentation-timing requirements must measure the horizon empirically over
many frames.

---

## Open question

The offset between `presentedTime` and light emission is unmeasured. Everything
above is the system reporting on itself.

Section 4 establishes that `presentedTime` marks the presentation event rather
than the end of scan-out, so the 1.65 refreshes is real latency and not a
timestamping artifact. What remains is the fixed constant from that event to
photons, which requires a photodiode on the flashing corner patch that every demo
draws. One measurement, once.

Until then: the intervals, the prediction accuracy and the scheduling behaviour
are all measured and reproducible; the absolute onset time is not.
