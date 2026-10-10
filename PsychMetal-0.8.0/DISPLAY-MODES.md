# Display modes and presentation in 0.7.2

PsychMetal draws directly with Metal on Mac, iPhone and iPad. MATLAB, Octave
and Python call the same engine. There is no OpenGL or Vulkan presentation path.

## Mac resolution and refresh selection

Enumerate the actual CoreGraphics modes before changing a monitor:

```python
import psychmetal as pm
print(pm.resolutions(0))
pm.resolution(0, 1920, 1080, refresh_hz=60)  # only if this fixed-rate mode exists
w, rect, ifi = pm.open_window(screen=0)
```

```matlab
PsychMetal('Resolutions', 0)
PsychMetal('Resolution', 0, 1920, 1080, 60); % only if listed
[w, rect, ifi] = PsychMetal('OpenWindow', 0);
```

Select a mode before opening a window. Width and height here describe logical
points; the mode list also reports the pixel backing dimensions. Among matching
point dimensions the selector prefers the largest pixel backing. With no refresh
argument it then preserves the current mode when possible; otherwise it prefers
the highest reported refresh. With an explicit rate, a fixed-rate mode must exist
within 0.01 Hz. A requested 60 Hz does not silently become 59.94 or 120 Hz.

A reported refresh of **0 means unknown or variable**, not 60 Hz. It is retained
in the mode list. You cannot request an arbitrary refresh that the hardware does
not offer. iOS does not expose desktop display-mode switching through this API.

PsychMetal matches the Mac window's NSScreen to the requested CoreGraphics display
ID. If that screen is unavailable, opening fails rather than selecting another
monitor. Screen indices describe the current display inventory and can change
when monitors are connected or disconnected.

## Logical points versus stimulus pixels

Stimulus positions and sizes use physical render pixels. The layer drawable must
match the selected display's pixel dimensions. PsychMetal rejects a scaled HiDPI
configuration that cannot provide the expected backing size; it does not silently
rescale a psychophysical stimulus. Check OpenWindow's returned rectangle and the
Diagnostic result on the monitor you will use.

## Presentation backend

The default on iOS 17+ is CAMetalDisplayLink. Each callback supplies the drawable;
the engine commits its command buffer and then presents that drawable, without
calling presentAtTime. Its preferred frame-rate range is a request to the system,
not a guarantee. Older supported iOS engines retain the direct Metal fallback.

Mac defaults to direct Metal presentation, including scheduled Flip, PrepareFlip,
QueueFlip and optional drawable prefetch. CAMetalDisplayLink is also available
explicitly via `presentation="displaylink"` in Python or
`struct('presentation', 'displaylink')` in MATLAB/Octave OpenWindow options. It requires synchronized presentation and owns drawable
acquisition. PrepareFlip, QueueFlip, and enabled prefetch are rejected in that
mode. Mac direct presentation remains the default because the two backends have
different scheduling contracts; changing that default needs hardware timing data.

An OpenWindow refresh override changes the engine's expected timing; it does
**not** change the display mode. Use a real fixed-rate display mode when fixed
cadence is needed, and base flicker periods on measured presentation intervals.
The blob-array demo uses even integer frame periods and measured refresh, so
its samples include both extrema. Disconnect Xcode debugging for phone timing tests.

## Pixel format and color

Eight-bit drawables use BGRA8Unorm. The optional Mac ten-bit path uses BGR10A2Unorm.
These are SDR paths; requesting ten bits does not prove ten-bit light output.
Both platforms explicitly use an unmanaged layer colorspace and disable EDR.
This preserves the numeric stimulus policy; it does not make different screens
photometrically equivalent. Linearize applies your supplied power law or measured
lookup table through a float intermediate. It cannot measure or calibrate a panel.

True Tone, Night Shift, brightness changes and system refresh policies can affect
measurements. Check the actual experiment setup with appropriate instruments.
Readback remains opt-in: ordinary windows keep framebufferOnly enabled and do not
copy every rendered frame for diagnostics.

Apple references: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink),
[drawableSize](https://developer.apple.com/documentation/quartzcore/cametallayer/drawablesize),
[colorspace](https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace).
