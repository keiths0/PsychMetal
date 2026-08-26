# Comparing PsychMetal against stock Psychtoolbox

`PsychMetal-0.4.0/PTBTimingTest.m` runs the same three workloads as the
PsychMetal demos through ordinary `Screen('Flip')`, and prints the same
statistics. Run both in one session, on one machine, and the two arms are
directly comparable.

## What to run

```matlab
% Standard Screen path, PTB's own sync tests allowed to run.
ptbDefault = PTBTimingTest(300);

% PTB's Vulkan display backend, if it is available on this installation.
ptbVulkan  = PTBTimingTest(300, 'vulkan');

% The PsychMetal arm, same session. One file per workload, since the single
% demo that used to run all three drew with Screen and was removed in 0.4.0.
pmRate     = PsychMetalRateCompare(300);    % test 1, unscheduled rate and spread
pmWhen     = PsychMetalWhenTest(300);       % test 2, scheduled at 1-4 refreshes
pmMouse    = PsychMetalMouseRectDemo(10);   % test 3, input to photons
```

Capture PTB's startup banner verbatim for each run. Whether it skipped the sync
tests, what it measured the refresh interval to be, and whether it warned about
the desktop compositor all change how the numbers should be read, and a forum
post without the banner invites the obvious objection.

Run with nothing else on the machine, on battery or mains consistently, and with
the display not mirrored or scaled. Run the whole set twice; if the two sets
disagree, that disagreement is the result.

## Reading the output

**Test 1, unscheduled presentation.** The comparison that matters is the interval
distribution, not the mean rate. Both paths will report close to 60 Hz. The
question is the spread: PsychMetal's p99 minus median across 300 frames is
0.000084 ms, two mach timebase ticks. Anything from PTB in the same range means
its ordinary path is fine on this hardware, which is what "timing seems fine for
the demos" would predict.

Watch `Missed`. PTB computes it as its own estimate of whether the flip made its
deadline, and a systematically positive median with no actual skipped refreshes
means the deadline model is wrong rather than the presentation.

**Test 2, scheduled presentation.** This is the arm that matters, and the gap
histogram is the part to read. A correct row has `achieved == waitframes` and
`correct == n`. How a failure fails is more informative than that it failed:

- Consistently one refresh late at every `waitframes` — a fixed offset in the
  deadline model. Recoverable.
- Correct at `waitframes` 1 and 2, wrong at 3 and 4 — matches the reported
  `VBLSyncTest([],n)` behaviour, and points at the scheduling horizon rather
  than at timestamping.
- Scattered across several gap values — the request is not being honoured at
  all, and the frames are landing wherever the pipeline puts them.

**Test 3, input to reported VBL.** Comparable to `PsychMetalMouseRectDemo` in
structure but not in kind — see below.

## The timestamps are not the same kind of measurement

PsychMetal reports `MTLDrawable.presentedTime`. `Screen('Flip')` returns PTB's
own VBL estimate, which on a machine without working beamposition queries comes
from a less direct method.

So:

- **Interval statistics are comparable.** Both measure the spacing between
  successive presentations, and a spacing is a spacing whatever the offset.
- **Absolute onset times are not comparable.** A difference in
  input-to-presentation between the two arms could be a real latency difference
  or a difference in where each timestamp sits relative to light emission.
- **Neither is photodiode-validated.** Both demos draw the flashing corner patch
  for exactly this reason. Until that measurement exists, present test 3 as a
  measurement of each system against its own timestamp, and say so.

That last point is worth stating explicitly in any post. It is the first thing a
careful reader will ask, and answering it up front is stronger than being
corrected.

## The `VBLSyncTest([],n)` failure

`VBLSyncTest`'s second argument is `numifis`, the number of refresh intervals
between flips; the first is the sample count. So `VBLSyncTest([],3)` asks for a
flip every third refresh, scheduled through `Screen('Flip')`'s `when` argument
using the standard `tvbl + (numifis - 0.5) * ifi` idiom — the same thing test 2
does independently.

Worth capturing, because "doesn't work" covers several different failures:

1. The exact console output and any error, verbatim.
2. Whether it errors, hangs, or completes with wrong numbers.
3. Whether `VBLSyncTest([],2)` really is clean, or merely less obviously broken.
4. The plotted or printed deviation — early, late, or scattered.

Then check it against test 2 at the same `waitframes`. If both fail the same way,
it is the scheduling path and not the test. If `VBLSyncTest` fails where test 2
succeeds, the difference is in what else `VBLSyncTest` configures, and reading
its source for the flip call and the options it sets will show what.

Read the local copy rather than a version from memory:

```matlab
edit VBLSyncTest        % or: type VBLSyncTest
which VBLSyncTest
PsychtoolboxVersion
```

## Result: `Screen('Flip', w, when)` does not honour `when`

Second run, `SkipSyncTests` 0, 149 scheduled flips per condition, both PTB arms:

| Requested | Achieved (median gap) | Correct | Median interval |
| --- | --- | --- | --- |
| 1 refresh | 1.00 | 149 / 149 | 17.03 ms |
| 2 refreshes | **1.00** | **0 / 149** | 16.99 ms |
| 3 refreshes | **1.00** | **0 / 149** | 16.97 ms |
| 4 refreshes | 0.00 | 0 / 149 | 8.26 ms + error |

Gap histograms, requested 2 and 3: every single presentation one refresh apart.
Not late, not scattered — the deadline is simply not being waited for. Asking for
a flip two refreshes out produces a flip at the next refresh, 149 times out of
149, in both the default and the Vulkan arm.

This is worse than the reported `VBLSyncTest([],n)` behaviour. It fails at
`n = 2`, not only above 2. Worth reconciling: if `VBLSyncTest([],2)` genuinely
looks clean, it is measuring something other than the realised interval, because
the realised interval here is one refresh.

At 4 refreshes it stops being a scheduling failure and becomes a hard error:

```
PsychVulkanCore-ERROR: vkWaitForPresentKHR(1): Failed due to timeout!
PsychVulkanCore-ERROR: PsychPresent(1): Failed to retrieve visual stimulus
                       onset timestamp! Timed out.
```

after which 85 of 149 successive timestamps are less than half a refresh apart —
degenerate values, not presentations at 120 Hz. The timestamping path gives up.

`PTBWhenBug.m` reproduces this in about twenty lines with no dependency on the
rest of this project. Run `PTBWhenBug(2)` and `PTBWhenBug(3)`; that output is
what belongs in a bug report, not the harness output.

## Both arms ran the same backend

The `mode` argument requested a backend but did not get one. In this session both
runs printed `Will try to use mechanisms in the external display backend for
accurate Flip timestamping`, both loaded MoltenVK, neither printed the desktop
compositor warning, and both produced the `PsychVulkanCore` error above. The
numbers agree to five significant figures — mean interval 16.664616 against
16.664538 ms, spread 1.8627 against 1.8700 ms — because they are the same
configuration measured twice.

So there is no clean OpenGL-path measurement with `SkipSyncTests` 0. The
OpenGL arm in the table below is from the earlier session, where `SkipSyncTests`
was 2 and the compositor warning did appear. PTB appears to engage Vulkan on its
own when sync tests are enabled, presumably because it will not offer
beamposition-free timestamps when it has been asked to care about timing.

Note also that `All startup display tests and calibrations disabled. Assuming a
refresh interval of 60.000000 Hz` still appeared with `SkipSyncTests` 0 — but
without the trailing `Timing will be inaccurate!` that the OpenGL path adds. The
Vulkan backend skips calibration deliberately.

## Comparison table

**Test 2 did not run** in the first session — a bug in the harness — and
`SkipSyncTests` was 2 throughout, so the PTB columns are provisional. See
"Caveats on the first run".

| | PTB `Screen('Flip')` | PTB Vulkan | PsychMetal 0.3.0 direct |
| --- | --- | --- | --- |
| Achieved rate (mean interval) | 60.007 Hz | 60.014 Hz | 60.000 Hz |
| Skipped refreshes / 300 | 0 | 0 | 0 |
| Interval median | 16.843 ms | 16.532 ms | 16.666708 ms |
| Interval p99 | 17.472 ms | 17.597 ms | 16.666792 ms |
| Interval max | 17.542 ms | 18.817 ms | — |
| p99 − median | 0.629 ms | 1.065 ms | **0.000084 ms** |
| `Missed` > 0 | 0 / 300 | 0 / 300 | n/a |
| Flip call duration, median | 16.001 ms | 15.559 ms | 15.342 ms |
| Scheduled, 1–4 refreshes | not run | not run | 300 / 300 at 1 |
| Mouse sample → reported onset | | | 48.05–48.33 ms |

### What this does and does not show

**All three arms present one frame per refresh with zero skips.** That is the
first thing to say, and it contradicts any reading of these numbers as "PTB
drops frames on this machine." It does not.

**The difference is timestamp precision, not presentation.** PTB's intervals
scatter over 0.6–1.1 ms; PsychMetal's over 84 nanoseconds. But PTB announces the
reason itself at startup:

```
PTB-INFO: Beamposition queries unsupported or defective on this system.
          Using basic timestamping as fallback.
PTB-INFO: Timestamps returned by Screen('Flip') will be therefore less
          robust and accurate.
```

Since no refresh was skipped in any arm, the frames are landing on the refresh
grid in all three. What differs is how precisely each system can tell you *when*
they landed. PsychMetal reads `MTLDrawable.presentedTime`; PTB, denied
beamposition queries, is estimating.

That is a real and useful advantage — knowing onset time to 84 ns rather than
±1 ms matters for anything time-locked to an external recording. But it is an
advantage in **measurement**, and these data do not show an advantage in
**presentation**. Claiming the latter from this table would be overreaching, and
it is the first thing a careful reader will catch.

**A mean-median discrepancy in the PTB rows.** The default arm reports a median
interval of 16.843 ms against a mean of about 16.665 ms. A median above nominal
with a mean at nominal and zero skips means the timestamps have a left tail —
some intervals reported short, compensating. This is timestamp scatter, not a
presentation pattern. The percentile row added to the harness will show its
shape.

**The Vulkan anomaly is worth a second look.** The Vulkan arm reported no
compositor warning and claimed `Will try to use mechanisms in the external
display backend for accurate Flip timestamping` — better timestamping on paper —
yet scattered 1.065 ms against the default path's 0.629 ms, with a worse maximum
(18.817 vs 17.542 ms). Either the external backend's timestamping is not helping
here, or this is single-run noise. Run both arms three times before drawing any
conclusion from it.

### Caveats on the first run

1. **`SkipSyncTests` was 2 for every PTB run.** `All startup display tests and
   calibrations disabled. Assuming a refresh interval of 60.000000 Hz` appeared
   in both, and the reported IFI is exactly nominal. PTB was therefore scheduling
   against a nominal grid, not a measured one — and the measured refresh on this
   machine is 59.99991 Hz, 2.5 ppm off. Over 300 frames that is only ~0.013 ms,
   too small to explain a 0.6 ms spread, but it invalidates the scheduled-flip
   arm entirely and has to be fixed before quoting anything.

2. **Test 2 never executed.** The scheduled-presentation arm — the one that
   matters, and the one `VBLSyncTest([],n)` exercises — has no data yet.

3. **The compositor was active for the default PTB arm** and PTB warned about it
   in the strongest terms it has. That warning belongs in any post alongside
   these numbers.

4. **One run each.** No repeat, so none of the differences above have an error
   bar.

## The input-to-onset numbers contradict each other, and that matters

Same machine, same session, same mouse-tracking workload:

| | Mouse sample → reported onset |
| --- | --- |
| PTB, default arm | 15.638 ms (0.938 refreshes) |
| PTB, Vulkan arm | 16.218 ms (0.973 refreshes) |
| PsychMetal direct, 2 drawables | 48.05 – 48.33 ms (2.90 refreshes) |

Read naively this says stock PTB is three times lower-latency than PsychMetal,
which would invert the entire premise of this project. **Do not post that
comparison.** It is not established, and it may well be an artifact.

PTB is reporting an onset less than one refresh after the mouse was sampled. In
that interval the frame has to be drawn, submitted, rendered by the GPU, handed
to the compositor or the swapchain, and scanned out. PsychMetal's own
instrumentation puts GPU completion alone at 1.6 ms after submission and
presentation at 1.65 refreshes after that — and that lower bound is a property of
the macOS presentation path, not of PsychMetal. A sub-one-refresh input-to-photons
figure on this hardware is not plausible.

Two explanations, and the data here cannot separate them:

1. **PTB's timestamp is stamped earlier in the pipeline** than PsychMetal's — at
   the swap request rather than at presentation. The physical latencies are
   similar and the 32 ms gap is a difference in where each clock is read.
2. **PsychMetal really is carrying more queue depth.** PTB's Vulkan swapchain
   reports `Created 2 swapchain images`; PsychMetal's naive path uses 2
   drawables but sits behind a measured 1.65-refresh presentation wait. We
   established earlier that each drawable costs exactly one refresh, so a real
   difference of one to two refreshes is not impossible.

The honest position is that PsychMetal's advantage is currently established in
**interval stability and timestamp precision**, and is **not** established in
latency. On latency the comparison is presently unresolved and leans against us.

A photodiode on the flashing corner patch settles it in a single afternoon, for
both systems at once, and it is now the highest-value measurement remaining in
this project — it decides whether PsychMetal is genuinely lower-latency or merely
better instrumented. Until then, any latency claim in a public post should be
stated as an open question.

### The reproducibility result

Worth noting separately, because it is strong. `PsychMetalLatchTest` was re-run
in a fresh session and reproduced the deadline sweep exactly: boundary step at
phase 0.650, fastest call-to-presentation 17.270 ms at phase 0.625 — identical
to the figures in `docs/05_results.md` section 6, to the millisecond. The mouse
demo likewise reproduced across three runs: 48.33 / 48.23 / 48.05 ms naive,
44.34 / 44.43 ms phase-targeted. The ~4 ms phase-targeting gain is real and
repeatable.

## What this can and cannot establish

It can establish whether stock PTB's ordinary presentation is frame-accurate on
this machine, whether its scheduled presentation places frames where it is asked
to, and how both compare to the Metal path under an identical workload.

It cannot establish which system's reported onset time is closer to the light,
and it cannot distinguish a PTB bug from a platform limitation that PTB is
correctly reporting. One machine, one display, one macOS version. Say so.
