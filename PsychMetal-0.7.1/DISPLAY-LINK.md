# Metal display-link presentation

The default `auto` selection uses CAMetalDisplayLink on iOS 17+ and direct
presentation on the Mac and older iOS. Explicit `displaylink` selection is
available on macOS 14+ and iOS 17+. Both render with the same native
Metal shaders; neither uses OpenGL or Vulkan.

Python:

```python
with pm.open_window(presentation='displaylink') as (w, rect, ifi):
    pm.fill_rect(w, 127.5)
    pm.flip(w)
```

MATLAB/Octave:

```matlab
[w, rect, ifi] = PsychMetal('OpenWindow', struct('presentation','displaylink'));
PsychMetal('FillRect',w,127.5);
PsychMetal('Flip',w);
PsychMetal('Close',w);
```

For the array, run `python/blob_array_demo.py --presentation displaylink`, or
`PsychMetalBlobArrayDemo(60,0.5,'displaylink')` from MATLAB/Octave.

## Phone timing

The iPhone app uses CAMetalDisplayLink by default on its supported iOS versions.
The presentation-comparison demos have been removed. Choose **Blob array** for
the draggable stimulus, or enable **Diagnostic mode** and select **Frame timing**
for a report using the same default presentation path. Neither captures images
or pauses after a missed frame. Three fingers returns to the menu.

Install with Xcode, stop debugging, then launch from the home screen for timing
measurements. In testing, disconnecting Xcode eliminated the periodic long
intervals seen while debugging.

## Implementation and limits

A dedicated native user-interactive thread runs CAMetalDisplayLink. Each Flip
requests one fresh update; unused callbacks are discarded rather than building
a queue of old drawables. The engine's calling thread receives that drawable,
encodes and commits the existing draw list, then calls `present` on the drawable.
Apple owns its presentation time; the predicted target is recorded for diagnostics
only. Timed presentation (`presentAtTime`) is forbidden on these drawables. There is no call to nextDrawable or manual prefetch on this path. The
requested frame latency is two frames and the requested refresh range is fixed
to the selected rate. These are requests, not physical timing guarantees.

This tests display-driven pacing while keeping the stimulus and host-language
work comparable. It does **not** make the entire animation autonomous: Python or
MATLAB still supplies each frame's drawing parameters. A pause in the host can
still cause a missed frame. Moving whole stimulus sequences into a native
scheduler would be a separate change if the comparison indicates a need.

The standard Flip API, including a future `when` target, uses display-link
updates in this mode. Future times select the first suitable update, not an
arbitrary sub-refresh onset. PrepareFlip, QueueFlip, manual drawable prefetch,
and disabling display sync are explicitly rejected, rather than silently using
the direct backend. Unsupported OS versions fail explicitly. Close invalidates
the link and joins its thread before destroying the layer.

Software timestamps do not measure emitted light; the selected backend cannot
guarantee physical presentation deadlines under every device workload.
