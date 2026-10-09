# In-app frame timing report

Select **Frame timing** in the phone app's Tests group. Keep the phone still
for the alternating patch and untouched blob array, then drag a blob during
the third condition. Each condition has one nominal second of warm-up and
12 nominal seconds of recording. Three fingers end the test early and show
whatever was collected. The total is approximately 40 seconds, longer if
frames arrive slowly.

When the stimulus window closes, a scrollable report opens inside the app.
Each condition has a presentation-interval graph, confirmed/unconfirmed frame
counts, long-interval counts, median/99th-percentile/maximum intervals, and
CPU, drawable-wait, encoding and GPU timing summaries. With at least three
long intervals it also reports their median and maximum spacing.

**Back to demos** returns to the menu. **View last timing report** reopens the
most recent report, including after another demo has run. Results remain in
memory until the app exits or a new timing report replaces them. No files,
internet connection, plotting package or native-wheel rebuild are needed.
Take screenshots of the report to keep or share it.

Graphs use Metal's actual presentation timestamps, never projected Flip
times. An interval requires adjacent submitted frames with confirmed,
increasing timestamps. Missing timestamps break the line. The green line
shows the nominal interval; red dots mark intervals above 1.5 or below 0.5
times that interval. Long intervals are not by themselves proof of dropped
frames or a refresh-rate change. The separate delivery rate counts confirmed
frames over their elapsed time, including gaps between them.

This first diagnostic uses the existing engine diagnostics. It does not yet
record CADisplayLink callbacks or measure physical light output, and cannot
prove that ProMotion changed cadence. The CPU measurements add a few clock
reads per frame; report generation occurs after the stimulus windows close.
The third condition counts touch events on a phone, or held-button samples on
a Mac. A third condition with no recorded input did not test dragging.

For a baseline, use a cool phone with Low Power Mode off and launch the app
without Xcode's debugger attached. Keep the phone orientation unchanged during
a run. Repeat a run to distinguish recurring behavior from a one-off stall.

## Compare Game Mode on and off

The app opts into iOS Game Mode with `GCSupportsGameMode = true` in its
Briefcase iOS configuration. This requests support; it is not a measurement
of whether Game Mode is currently active.

Rebuild and install the app, then check for Game Mode in the system's Game
Overlay (open Control Centre while the app is running). Run **Frame timing**
once with Game Mode on and once with it off, keeping other conditions the
same. Change the setting before starting each test, not during recording.
Take screenshots of each report and note which setting was used. The report
does not automatically detect or label Game Mode's current state.

Game Mode reduces background activity but does not guarantee every deadline
or a fixed physical refresh rate. See [Apple's configuration guidance](https://developer.apple.com/videos/play/wwdc2024/10089/)
and [Game Mode controls](https://support.apple.com/105118).

Briefcase update copies Python code but does not refresh arbitrary Info.plist
keys in an existing Xcode project. Newly created 0.7.1 projects inherit it from pyproject.toml. The older local
0.7.0 project was patched separately.

## Diagnostic mode (0.7.1)

The main menu's **Diagnostic mode** switch starts off. Turn it on before running
Frame timing to receive timing output and its graph. It is locked during a run.
With it off, demo standard output and new timing reports are suppressed; errors
remain visible. Blob array also skips its final timing analysis. Previously
saved reports remain available through **View last timing report**.

With Diagnostic mode on, **Blob array** collects final timing statistics but
continues through missed frames. The phone app never enables frame capture or
auto-pause. The phone app uses CAMetalDisplayLink on its supported iOS versions;
the former presentation-comparison menu items have been removed.

The optional desktop `--inspect-frames` argument still enables the legacy
inspector explicitly. It pauses on a confirmed long interval or a reported
dropped frame. Its Previous/Next/Resume/Quit controls are described below.

The inspector retains up to eight full-resolution RGB frames, within 128 MiB.
It starts on the event frame if retained and labels each frame relative to it.
If confirmation arrives after that frame expires, a warning identifies the
nearby retained frames. Captured pixels are immutable while inspecting; UI
frames and pause duration are excluded by resetting detection on resume.

These are GPU-rendered pixels, not a recording of the physical panel or
compositor output. Synchronous readback can itself cause missed refreshes.
Use the separate **Frame timing** test for timing without capture overhead.
The captured session intentionally does not print an aggregate frame-rate
summary polluted by the inspection screen. A clean captured Gaussian during
a visible square flash would point beyond the rendered drawable, but would
not by itself identify the cause.

On a Mac, opt in explicitly:

```python
import psychmetal as pm
from blob_array_demo import blob_array_demo
pm.run(blob_array_demo, diagnostic=True, inspect_frames=True)
```

Implementation: `pm.recent_frames(w, count=32)` snapshots bounded frame records
without draining GPU work. Pending callbacks remain pending; only consecutive
confirmed positive presentation times are used to infer long intervals.
This API is currently exposed in Python. GPU capture, native touch controls,
and visual results still require testing on the device.

Timing-test labels use the device safe-area insets (converted from points to drawable pixels), including the camera island and landscape cutouts. Geometry is queried before warm-up, outside measured frames. Frequency labels are kept within these bounds while dragging.

## Frame-count sampling in the blob array

The Python, phone, and MATLAB/Octave arrays now measure the confirmed refresh
 grid during a brief gray startup, requiring at least 30 confirmed samples.
They never silently substitute a nominal rate when calibration is unavailable.
The displayed frequency is measured refresh rate divided by frames per cycle.
Periods are 2, 4, 6, 8, then powers of two down to approximately 1 Hz. For a
119.88 Hz display, the first labels are 59.94, 29.97, 19.98, and 14.98 Hz.

Every period is even. Precomputed cosine samples advance by integer frame
count and include the exact maximum and minimum. Four frames give maximum,
gray, minimum, gray; six give maximum, two intermediate levels, minimum,
and the same intermediate levels in reverse. Three frames (40 Hz at 120 Hz)
cannot sample both sinusoidal extrema at equal phase intervals.

Labels describe the measured cadence at startup, not a guarantee against
missed refreshes or later adaptive-refresh changes. A missed refresh prolongs
a displayed sample. Calibration frames are excluded from the demo report.

The paused capture inspector respects display safe-area insets and sleeps
normally between updates. Finger-ring and annulus reports now use confirmed
presentation timestamps, excluding unconfirmed adjacent intervals.

## Whole-second recurrence investigation

Frame timing records a detail row for every confirmed long adjacent
interval, with elapsed presentation time, signed distance from the nearest
whole second, previous/current input-and-drawing work, Flip, encoding and GPU
execution durations. Elapsed zero is the first confirmed measured frame.

A bounded Python garbage-collection monitor records collection start/stop times.
The report identifies collections overlapping the current or preceding CPU
frame, without claiming causality. Total collection counts include warm-up;
trace overflow is reported. Callback registration is removed even if a test
fails. Frame timing buffers are preallocated instead of growing per-frame lists.
Instrumentation adds some overhead and does not disable garbage collection.

The per-interval console output can be pasted directly for diagnosis; no images
are captured. No once-per-second label update exists in the blob-array loop.
