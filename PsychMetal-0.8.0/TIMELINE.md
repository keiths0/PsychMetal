# Native captured-scene timelines — 0.8.0 development

Queue a scene once, then replay it with native frame-counted modulation. The
playback call blocks until completion or cancellation. No Python/MATLAB calls
occur between its frames. It uses the existing native `Flip` path: the selected
Mac presentation backend, and the automatic iOS 17+ display-link backend. This is
not a guarantee of uninterrupted physical presentation.

```python
w, rect, interval = pm.open_window()
try:
    pm.background_color(w, 127.5)
    blob = pm.make_stimulus('grating', frequency=0, aperture='gaussian')
    pm.draw_stimulus(w, blob, [100, 100, 400, 400])
    result = pm.play_timeline(w, 600, [[0, 1, 1, 4, 360, 0]])
finally:
    pm.close(w)
```

Equivalent MATLAB/Octave: `PsychMetal('PlayTimeline',w,600,[1 1 1 4 360 0])`
after `MakeStimulus` and `DrawStimulus`. The window must be the current draw target
and no `PrepareFlip` frame may be outstanding. Calling with no tracks replays a
static scene. Frame count must be an integer from 1 to 1,000,000.

Run `python/timeline_demo.py --seconds 20` with the built 0.8.0 Python package,
or `PsychMetalTimelineDemo(20)` with 0.8.0 on the MATLAB/Octave path. The demos return presentation statistics after playback and
measure confirmed refresh intervals before displaying frequency labels. They
show fixed Gaussian blobs; the existing draggable blob demo remains available.
On iOS call through the existing `pm.start(...)` worker from the app, keeping the
UIKit event loop alive. The 0.8.0 phone menu lists this under Diagnostic mode; physical device validation remains required.

## Track format

Each row contains `[drawIndex, parameter, kind, period, amplitude, offset]`.
Indices count every queued native draw, including shapes and text; text wrapping
can produce several draws. Queue stimuli before labels to keep indices simple.
Python/native indices start at **0**, MATLAB/Octave indices at **1**. Only
procedural `DrawStimulus` draws can be animated.

| Parameter | Meaning | Permitted values |
|---|---|---|
| 0 | Contrast | 0 to 1 |
| 1 | Phase | Degrees, within ±1,000,000 |
| 2 | Horizontal translation | Pixels relative to original destination |
| 3 | Vertical translation | Pixels relative to original destination |

Translations must keep destination edges within ±1,000,000 pixels. Each draw
parameter can have only one track. Kind **0** is cosine:
`offset + amplitude*cos(2*pi*(frame % period)/period)`.
Kind **1** is a periodic ramp:
`offset + amplitude*(frame % period)/period`.
Periods must be even integers from 2 to 1,000,000. Bounds are checked before
consuming the queued scene; tracks are copied, so host arrays are not read during
playback. Even periods with a 360-degree phase ramp start at the cosine maximum
and include the minimum halfway through the cycle. The nominal stimulus frequency
is **refresh rate / period**; the frequency it actually had is in the result
(below).

A cycle advances one sample for each submitted frame. If a refresh is missed,
this version does not skip ahead or repeat the prior sample to repair it, so the
result reports what the display did, from its own reports of each frame:

| Field | Meaning |
|---|---|
| `submitted` | Samples submitted. `firstToken` and `lastToken` are their frame tokens. |
| `shown` | Samples the display reported shown. `submitted - shown` were never shown, or never reported. |
| `late` | Samples shown more than half a refresh after one refresh per sample since the last shown sample: the sample before stayed on screen too long. |
| `lateRefreshes` | The refreshes those cost. |
| `firstLateSample` | The first late sample: zero-based in Python, one-based in MATLAB/Octave; NaN if none. |
| `meanSampleMs` | How long a sample actually stayed on screen, on average. The stimulus's actual frequency is its nominal frequency × (refresh period / `meanSampleMs`). |
| `longestIntervalMs` | The longest time between two shown samples. |
| `expectedRefreshHz` | The engine's refresh estimate when playback started, from which `late` is judged. |

A missed refresh, a refresh-rate drop (thermal limits, Low Power Mode on a
phone) and a frame the display never showed all appear here, on either
presentation backend. The display's reports for the last few frames arrive after
the last submission; playback waits for them briefly (up to about eight refreshes)
before returning. These are the display's reports of presentation, not
measurements of emitted light. `Diagnostic`/`pm.diagnostic(w)` after playback
gives every frame's record, and `RecentFrames` (Python) a bounded snapshot.

Escape or three fingers on iOS cancels between submissions. Python `pm.stop()`
ends a playback that is running, or the next one if it arrives just before
playback starts: the request is kept until a playback ends by it, so it cannot
be lost between Python's check and the native loop. `start()` and `run()` clear
it. MATLAB and Octave run nothing else while `PlayTimeline` blocks, so there
Escape is the way to end it. Closing the window is caller cleanup. Captured
texture versions remain retained throughout playback and GPU use; completion,
cancellation and presentation errors release the queued scene. Validation
errors, an iOS app no longer in front and frames still queued by `QueueFlip` are
refused before the scene is consumed, and leave it intact.

## Keyframes and live updates

Python accepts `keyframes=` as an optional N × 4 array of
`[drawIndex, parameter, frame, value]`. MATLAB/Octave accepts it after the periodic
tracks: `PsychMetal('PlayTimeline',w,frames,tracks,keyframes)`. Draw indices follow
the language convention above; frame indices always start at zero. Samples are
linearly interpolated, with endpoint values held before/after the supplied range.
Frames must increase strictly within each draw/parameter track. A parameter cannot
have both periodic and keyframe tracks. All values and translation bounds are
validated before playback consumes the queued scene.

During Python playback another thread can steer it: it can read input
(`get_mouse`, `mouse_events`, `touch_events`, `kb_check`, the keyboard queue),
wait (`wait_secs`), and call
`pm.update_timeline([[drawIndex,parameter,value], ...])`. Calls that draw or
change the window wait until playback ends. MATLAB and Octave have no live
updates: they cannot run code while blocked in the call.
Updates take precedence over periodic/keyframe tracks and persist until playback
ends. Each batch is validated and applied atomically; the render loop never waits
for the update lock. Only parameters 0–3 of existing procedural draws can change;
textures, shader programs and scene geometry cannot be replaced during playback.

This version has no arbitrary host callbacks, video, or custom shader tracks. It reuses the existing native
presenter rather than installing a separate competing display-link loop. CPU
regressions and SDK builds do not replace Mac/iPhone visual and timing acceptance.
