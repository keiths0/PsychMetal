# Display modes and presentation

PsychMetal draws directly with Metal on Mac, iPhone and iPad. MATLAB, Octave
and Python call the same engine. There is no OpenGL or Vulkan presentation path.

## Which display

With more than one display, `screens()` / `PsychMetal('Screens')` lists them:
the number OpenWindow takes, 0 the main display (the one with the menu bar), as
`Screen('Screens')`, with each display's name, size in points and pixels,
refresh rate (0: unknown or variable), and whether it is the main or built-in
one. OpenWindow with no screen opens on the last display, usually an external
one. The window covers that display and captures it; the others stay usable.

```python
for s in pm.screens():
    print(s['index'], s['name'], s['pixelWidth'], s['pixelHeight'], s['hz'])
w, rect, ifi = pm.open_window(1)          # the second display
```

```matlab
[screens, info] = PsychMetal('Screens');   % screens is 0:n-1
[w, rect, ifi] = PsychMetal('OpenWindow', max(screens));
```

So far this has been run with one display only; opening on a second display
has not been tested.

## Display capture and startup

The display a window opens on is captured while it is open (`capture_display`,
on by default; off with `hdr`): nothing else draws on it, and Mission Control
and Space switching are off. Control-C or Command-period in the window stops the
program. It stays on by default because a stimulus that does not own the whole
screen goes through the window compositor; `capture_display=False` /
`captureDisplay=false` is for comparison only, and diagnostics report whether
the display was captured. Opening waits for two consecutive confirmed
presentations, within two seconds, instead of a fixed one-second delay;
`PsychMetalOpenReadyTest(50)` in MATLAB or Octave checks fifty opens.

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

Mac defaults to direct Metal presentation, including scheduled Flip and
QueueFlip. In it each frame gets its drawable as late as possible, after its
drawing has been queued, as Apple advises. CAMetalDisplayLink is also available
explicitly via `presentation="displaylink"` in Python or
`struct('presentation', 'displaylink')` in MATLAB/Octave OpenWindow options. It owns drawable
acquisition, and QueueFlip is rejected in that mode. Mac direct presentation remains the default because the two backends have
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
