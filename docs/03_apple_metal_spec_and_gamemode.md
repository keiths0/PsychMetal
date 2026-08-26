# PsychMetal: aligning with Apple's Metal specification, and Game Mode

> **Historical. Written against 0.2.0; Game Mode was removed in 0.3.1.** It
> required AppKit managed fullscreen, which cannot position correctly on a
> notched display and was itself removed, and it was measured to do nothing in
> direct presentation mode (1.658 against 1.655 refreshes). It also required
> declaring the host application a game in its `Info.plist`, which a MEX file
> cannot do. Its one real effect — a refresh off the `CAMetalDisplayLink`
> path — is recorded in `05_results.md` section 3.
>
> The Metal-specification half of this document is still accurate and still
> describes what the code does: layer properties, direct scanout eligibility,
> drawable lifetime and the `presentedTime` contract.

Against 0.2.0 (build f9b2a03e).

---

## Part 0 — One thing in the current build to correct first

```objc
driver.link.preferredFrameLatency = 1;
effectiveFrameLatency = driver.link.preferredFrameLatency;
```

This reads back the property you just wrote, so it will always return 1.0. Apple's statement
is that "the final latency may be bigger if the system needs more time" — that is *runtime
behaviour*, not something reflected in the property. So `requestedFrameLatency` and
`effectiveFrameLatency` will always agree, and reporting them side by side implies a
verification that isn't happening.

Two fixes:

- `mxSetField(..., "requestedFrameLatency", mxCreateDoubleScalar(1))` hardcodes the 1. Store
  the requested value in a static and report that, so the two can't desync.
- Rename `effectiveFrameLatency` to `frameLatencyReadback`, and add
  `observedFrameLatency = calibratedTargetLagFrames`, which is the *measured* answer you
  already compute. That pair is meaningful; the current pair is not.

The latency sweep (run identically at 1.0 and 2.0, compare `calibratedTargetLagFrames`) is
still the outstanding measurement, and it is still the one that tells you whether you are on
the compositor bypass.

---

## Part 1 — Metal's three presentation methods

You use only `presentDrawable:`. Metal documents three, and the other two map directly onto
things PsychMetal currently implements by hand.

| Method | Documented behaviour | Available |
| --- | --- | --- |
| `presentDrawable:` | Present as soon as possible. | all |
| `presentDrawable:atTime:` | "Presents a drawable at a specific time." Parameter is "the Mach absolute time, in seconds, that you want to present the drawable." | macOS 10.11+ |
| `presentDrawable:afterMinimumDuration:` | "Presents a drawable after the system presents the previous drawable for an amount of time." Parameter is "the shortest display time you want the system to give to the previous drawable before presenting this one." | macOS 10.15.4+ |

Both are convenience methods that call the drawable's corresponding `present` after the queue
schedules the command buffer, and both **must be called before `commit`**.

### 1.1 `atTime:` — exact placement for `when`

Your live-gate design already picks the right tick. `atTime:` places the frame *within* that
tick against the same Mach timebase you already measure, which means the correction only has
to be good enough to select the tick — not good enough to predict the timestamp.

Carry the requested time to the callback (it's already on the `Record`; read it back under the
lock when the frame is accepted) and replace the present call:

```objc
    if (isfinite(requestedTime) && requestedTime > CACurrentMediaTime())
        [cb presentDrawable:d atTime:requestedTime];
    else
        [cb presentDrawable:d];
```

**Spike this before wiring it in.** In the callback, temporarily present at
`u.targetPresentationTimestamp + ifi` and check whether confirmed `presentedTime` follows. If
the frame presents at the original tick regardless, `atTime:` is being ignored in this
configuration and you keep the gate alone.

### 1.2 `afterMinimumDuration:` — the documented `waitframes`

This is the one worth the most to you. "Show this stimulus for exactly N refreshes" is the
bread-and-butter psychophysics operation, and Apple provides it directly: the *system*
guarantees the previous drawable gets its minimum display time, rather than your code
deferring submission and hoping.

```objc
    [cb presentDrawable:d afterMinimumDuration:waitFrames * ifi];
```

Expose it as an explicit argument rather than inferring it from `when`:

```matlab
PsychMetal('Flip', w, when, waitframes)
```

It is a different guarantee from `when`, and worth having both: `when` anchors to an absolute
time (an external trigger), `afterMinimumDuration:` guarantees a display duration. Report both
paths separately in `Diagnostic` so you can compare which produces tighter intervals — that
comparison is itself a result.

### 1.3 The constraint that applies to both

`maximumDrawableCount = 2`. A drawable held for a distant future time occupies a slot in that
pool, so the display link cannot acquire another and will start delivering nil drawables
(your status 4). Neither method should be used to implement a multi-second hold — keep the
tick gate for that and use these for short leads of one to three refreshes.

---

## Part 2 — Other documented settings worth revisiting

**`maximumDrawableCount`.** Documented range is 2–3. You use 2, which minimises latency and
maximises drop risk. Now that status-4 drops are visible and counted, run the same
drop-rate comparison you'll run for `preferredFrameLatency`. Two knobs, four combinations,
and the answer is a table.

**`presentsWithTransaction`.** The documented alternative for tight control: with it set, you
`waitUntilScheduled` and then present explicitly, synchronising presentation with the Core
Animation transaction instead of letting the render server schedule it. It costs a block on
the calling thread — which you have budget for — and it removes a layer of scheduling you
currently cannot see into. Worth a spike alongside 1.1.

**`gpuStartTime` / `gpuEndTime` on `MTLCommandBuffer`** (macOS 10.15+). Record these in
`addCompletedHandler` and expose `gpuPassMs`. It tells you exactly how long the
IOSurface→drawable pass takes, which is currently the one segment of the pipeline you have no
number for. Three lines, and it completes the picture alongside `glSyncMs` and
`renderBudgetMs`.

**`MTLCommandBufferDescriptor.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus`.**
You currently store `x.status` as a bare int. With this option set, a failed command buffer
tells you which encoder failed. Cheap, and turns a status-3 row from "something went wrong"
into a diagnosable event.

---

## Part 3 — Game Mode

### What actually triggers it

Game Mode is gated on Info.plist keys in the **host application bundle**, read by Launch
Services at process launch:

- `LSApplicationCategoryType` = `public.app-category.games`
- `GCSupportsGameMode` = `true`
- `LSSupportsGameMode` = `true` (macOS 26 and later)

Plus the runtime condition you already satisfy: the app must enter **the native macOS
fullscreen mode** — the one with the system fullscreen button, on its own Space. Requires
Apple silicon and macOS 14+.

Two consequences for PsychMetal:

1. **The "slide in" you're seeing is the native fullscreen Space transition, and you already
   do that.** That part isn't Game Mode; it's what `toggleFullScreen:` does. The "Game Mode is
   on" banner is the additional thing, and it needs the plist keys.
2. **A MEX file cannot enable it.** These keys are read from the bundle at launch. There is no
   runtime API, and the process's bundle is MATLAB's or Octave's — both of which declare
   themselves as developer/productivity applications. Nothing PsychMetal does from inside the
   process can change that.

Apple is also explicit that eligibility is not a guarantee: "the OS decides if it is ok to
enable Game Mode at runtime."

### Making it testable — Octave

Octave ships as a normal app bundle, so a copy with the keys added is a clean A/B against an
unmodified one:

```sh
cp -R /Applications/Octave.app /Applications/Octave-GameMode.app
P=/Applications/Octave-GameMode.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set  :LSApplicationCategoryType public.app-category.games" "$P" \
  || /usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.games" "$P"
/usr/libexec/PlistBuddy -c "Add :GCSupportsGameMode bool true" "$P"
/usr/libexec/PlistBuddy -c "Add :LSSupportsGameMode bool true" "$P"

# Editing Info.plist invalidates the outer signature; ad-hoc re-sign the bundle.
codesign --force --sign - /Applications/Octave-GameMode.app

# Launch Services caches bundle metadata; re-register so the new category is seen.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/Octave-GameMode.app
```

Then run `PsychMetalWhenTest` from each bundle and compare `calibratedTargetLagFrames`,
the status-4 drop count, and the confirmed interval distribution. Same code, same display,
one variable.

**MATLAB**: the same edit applies in principle to `MATLAB.app/Contents/Info.plist`, but it is a
large signed bundle with license checks and re-signing is considerably more likely to break
the launch. Test on Octave first; only touch MATLAB if the Octave result is interesting.

**Don't redistribute either.** Apple notes that an app declaring Game Mode which isn't a game
gets rejected by App Review. Irrelevant for a local research build, but this is a local
experiment, not something to ship in the PsychMetal zip.

### Recording eligibility in the diagnostics

Whether or not you pursue the bundle experiment, the process's category is queryable and
belongs in every run's record, so timing numbers can't be compared across bundles by accident:

```objc
NSBundle *main = NSBundle.mainBundle;
NSString *category = [main objectForInfoDictionaryKey:@"LSApplicationCategoryType"];
NSNumber *gcSupports = [main objectForInfoDictionaryKey:@"GCSupportsGameMode"];
```

Add `summary.hostBundleIdentifier`, `summary.hostAppCategory`, and
`summary.gameModeEligible = [category isEqualToString:@"public.app-category.games"] && gcSupports.boolValue`.

### The honest expectation

Game Mode's documented benefits are CPU/GPU scheduling priority for the foreground app and
reduced latency for wireless controllers and audio. Your loop is idle roughly 80% of each
frame and has essentially no contention, so the priority benefit is plausibly near zero.

The reason to run the experiment anyway is the *undocumented* question: whether Game Mode
changes the compositing path. If `calibratedTargetLagFrames` drops when Game Mode is active,
that is direct evidence that the non-Game-Mode path is being composited — which is the same
question the `preferredFrameLatency` sweep is asking, approached from the other side. Two
independent tests converging on the same answer would be a strong result for the forum post.

---

## Suggested order

1. Fix the frame-latency readback reporting (Part 0) — it currently implies a check that isn't happening.
2. Run the `preferredFrameLatency` 1.0/2.0 sweep. Still the highest-value outstanding measurement.
3. Add `gpuStartTime`/`gpuEndTime` and the bundle-eligibility fields — both small, both complete the diagnostic picture.
4. Spike `presentDrawable:atTime:` and `presentsWithTransaction`.
5. Implement `afterMinimumDuration:` as an explicit `waitframes` argument.
6. Build the Octave Game Mode bundle and run the A/B.

---

## Sources

- [MTLCommandBuffer.present(_:atTime:)](https://developer.apple.com/documentation/metal/mtlcommandbuffer/present(_:attime:))
- [MTLCommandBuffer.present(_:afterMinimumDuration:)](https://developer.apple.com/documentation/metal/mtlcommandbuffer/present(_:afterminimumduration:))
- [CAMetalDisplayLink.preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency)
- [Use Game Mode on Mac — Apple Support](https://support.apple.com/en-us/105118)
- [Activate Game Mode for my App — Apple Developer Forums](https://developer.apple.com/forums/thread/739387)
