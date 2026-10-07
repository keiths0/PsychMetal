# PsychMetal 0.7.0 — GPU stimuli development build

New reusable GPU noise/grating recipes, independent image/ellipse/Gaussian masks and per-draw phase, frequency, orientation, contrast, seed and opacity. See [GPU-STIMULI.md](GPU-STIMULI.md) for the API, demos, conventions and validation limits.

This is an unpublished development build based on 0.6.0. All three native modules build; live GPU pixels and timing still require acceptance. Start with `PsychMetalStimulusDemo` or `python/stimulus_demo.py`. Use the 0.7.0 folder in the installation examples below. Historical validation results below apply to their named versions, not this build.

This build also holds a port of the engine to iPhone and iPad, for Python only, and an app that runs this package's demos there ([phone/](phone/README.md)). It builds and runs on an iPhone 18 Pro; nothing on it has been timed. See [IOS.md](IOS.md).

## What changed in 0.6.0

0.6.0 includes everything that was in the unreleased 0.5.2.

**A frame that was not shown no longer stops the program.** When the display reports that a submitted frame never appeared, `Flip` used to raise an error. It now returns the frame's projected time, and `PsychMetal('FlipInfo', w)` (`pm.flip_info(w)`) reports `dropped` for the last flip and `droppedFrames` for the session, with `confirmed`, `slipped`, `queueMs` and `flipMs`. The display reports on a frame about a refresh after `Flip` has returned (unless the window waits for confirmation), so `FlipInfo` asks the engine when it is called: straight after `Flip`, `confirmed` and `dropped` are both false, and the next `Flip` makes them about the next frame. In a loop that flips every refresh, read `droppedFrames` when the trial or block is over: it counts every frame the display has reported never shown, queued frames included, whenever the report came. A GPU failure, no drawable or a confirmation timeout still raise.

**Linearization.** `PsychMetal('Linearize', w, 2.2)` (`pm.linearize(w, 2.2)`) makes every colour and texture value linear light for a display whose light is its input raised to that gamma; `[r g b]` gives one per channel. Drawing and blending then happen in a 16-bit float frame, and a last pass writes display values. Blending is therefore correct in light: white at half alpha over black is half the light, where without linearization it is half the value, about a fifth of the light. A measured display takes a table instead: `PsychMetal('Linearize', w, table)`, N×3, the display value 0–1 for each of N evenly spaced linear values, interpolated. `[]` (`None`) turns it off. It costs one more full-screen pass per frame. PsychMetal does not measure the display: the gamma or table must come from a photometer.

**Ten bits per channel.** `PsychMetal('OpenWindow', struct('bitDepth', 10))` (`pm.open_window(bit_depth=10)`) asks for a 10-bit frame. Colours and float textures then resolve 1024 levels, and `GetImage` returns uint16 running 0–1023. Whether the ten bits reach the panel is not something PsychMetal can check.

**Blending.** `PsychMetal('BlendFunction', w, 'add')` (`pm.blend_function(w, 'add')`) makes what is drawn from then on add to what is there, colour times alpha, so overlapping draws sum; `'alpha'` is the default. The mode belongs to each draw as it is queued. Without linearization each draw saturates at white as it is drawn; with it, sums above white are kept until the frame is written, so a later draw can bring them back down.

**Text.** `PsychMetal('DrawText', w, 'Press a key', x, y, color, size, font)` (`pm.draw_text`) draws one line with its top left at x, y; `[]` (`None`) for either centres it. Size is in pixels, a thirtieth of the window height by default; the font is a name, Helvetica by default, and an unknown name draws in a substitute without error. It returns the rect it drew and the ascent. `TextBounds` (`text_bounds`) measures without drawing. Text is drawn in order with everything else, takes the blend mode and linearization, and each new string, font or size is rendered once and kept: up to 256 renderings or 256 MB, shared with polygons, the ones wanted longest ago making way, so fixed text stays while changing text passes through. Measuring renders nothing.

**Part of a texture.** `PsychMetal('UpdateTexture', w, tex, image, rect)` (`pm.update_texture(w, tex, image, rect)`) replaces only `rect`, `[left top right bottom]` in texture pixels and the size of the image, in place. Changing a small part of a large texture costs the small part. The image must have the texture's kind (uint8 or logical, or float) and channels, and the texture must not be in a frame that is drawn but not yet flipped.

**The display link.** `PsychMetal('LinkInfo', w)` (`pm.link_info(w)`) reports the DisplayPort link to the display: `lanes`, `laneGbps`, `payloadGbps` (what it carries), `pixelGbps` (what this window needs) and `compressed`, 1 when the picture cannot fit and the link must be compressing it. `OpenWindow` prints two lines when that is so. The values are NaN when the link cannot be identified (a built-in panel, HDMI); the registry entries it reads are not a documented interface.

**A display test.** `PsychMetalDisplayTest` (`python/display_test.py`) shows what readback cannot see. It reports the link, then shows static single-pixel noise beside a patch that changes, in colour and then in grey (twinkling in the static noise means the link is altering it, and it can alter one and not the other), a static field beside a changing one (a darker changing field means the panel's pixels do not settle within a frame), and single-pixel stripes around a grey to match, a single quick estimate of gamma that the gamma calibration replaces with a measured curve. It asks what you see and prints what follows from it.

**Offscreen windows.** `[woff, rect] = PsychMetal('OpenOffscreenWindow', w, color, rect)` (`pm.open_offscreen_window`) makes a window that is not shown. Every drawing command takes `woff` in place of `w` and draws into it; what is drawn stays until it is drawn over, and `PsychMetal('DrawTexture', w, woff, ...)` draws it like any texture, as often as you like. A picture that is expensive to draw and does not change is drawn once. It holds half-float values, so nothing is rounded on the way in. An alpha of 0 in `color` makes it transparent, and `BlendFunction` `'copy'` replaces what is there, alpha included, which is how to clear it. Where it is partly transparent it holds colour already multiplied by alpha and is drawn as such, so drawing it onto the window gives what the same draws made on the window would have given, soft edges and overlaps included, and a global alpha applies to everything in it. Two limits: a draw of it that is waiting for `Flip` must be flipped before you draw into it again (the call is refused, not silently wrong); and it cannot be drawn into itself.

**Polygons and a clip rect.** `PsychMetal('FillPoly', w, color, points)` and `PsychMetal('FramePoly', w, color, points, penWidth)` (`pm.fill_poly`, `pm.frame_poly`) fill or outline a polygon given as N×2 points, antialiased, concave or self-crossing (even-odd rule). The polygon is rendered on the CPU into a coverage mask and kept, so one that only moves by whole pixels is rendered once; a different shape on every frame is rendered on every frame. `old = PsychMetal('Clip', w, rect)` (`pm.clip`) confines everything drawn from then on to a rect, and `[]` (`None`) ends it.

**Text in lines.** `DrawText` and `TextBounds` take newlines, and an eighth argument (fifth for `TextBounds`), `wrapWidth` in pixels, breaks lines between words. With x empty each line is centred; with y empty the block is.

**Frames queued ahead.** `Flip` shows one frame and the program must be back in time to draw the next. `[token, pending, capacity] = PsychMetal('QueueFlip', w, when)` (`pm.queue_flip`) instead renders the frame now, keeps it, and returns at once; a thread in the engine shows it at the refresh at or after `when`. Queue frames in order of time, as far ahead as `capacity` allows (as many frames as fit in a gigabyte, at most 64, so about 13 at 6016×3384). The program can then stall for that many frames, for a garbage collection or a disk read, without a frame being late. `frames = PsychMetal('QueueResults', w)` (`pm.queue_results`) waits and returns one row per frame, `[requested presented status token]`, each frame once with its outcome (a frame still pending two seconds after the last frame's time is reported as pending, and again by the next call, until ten seconds after its own time); `QueueCancel` abandons frames not yet handed to the display. A late frame is shown at the next refresh, never skipped. `Flip` waits for queued frames before showing its own. This is untested on hardware: whether frames land on the refresh asked for, and how late the program can be, are to be measured.

**Input timed by its events.** Key times in the keyboard queue used to be the time of the polling scan that found the key, good to the poll interval (2 ms). Where the application is allowed Input Monitoring (System Settings, Privacy & Security), they are now the time the key event itself carries, and `KbQueueStatus` reports `eventTimestamps` 1. Without the permission the queue polls as before and says so once. Polling keeps running as a safety net either way. `[events, dropped] = PsychMetal('MouseEvents', w)` (`pm.mouse_events`) returns button presses and releases since the last call, `[time button pressed x y]`, with the events' own times; the first call starts listening. An event's time is when the system received it, which is after the switch closed by the device's own delay (up to 8 ms for an ordinary USB keyboard polled at 125 Hz). These times are unvalidated: the clock the event timestamp is on is inferred at run time, and has not been checked against a known signal.

**A gamma calibration by eye.** `PsychMetalGammaCalibration` (`python/gamma_calibration.py`) measures the display's response as well as an eye can. A pattern that is half one grey and half another emits the mean of their light whatever the gamma, so a uniform square adjusted to match it emits a known fraction of white. The short form, the default, is four matches and takes a minute or two: half of white against black-and-white rows four pixels thick and against columns (agreement between the two is evidence that the pattern is at its mean light, and their mean is used), then a quarter and three quarters by halving. It reports the best power law, how far gamma 2.2 and the sRGB curve are from the matches, and a 256×3 table for `Linearize`; then, with the table in use, it shows half against stripes and asks whether they match. The grey's number is hidden while you match, and each tap of an arrow key is one level. `struct('full', true)` (`--full`) is the long form, about ten minutes: half of white against nine patterns (rows and columns 1, 2, 4 and 8 pixels thick, and a checkerboard), which shows whether fine patterns are at their mean light, then seven levels from an eighth to seven eighths, every match twice. `struct('channels', 'rgb')` (`--channels rgb`) measures red, green and blue separately. It finds greys that match to about a grey level. It does not measure light, measures nothing below the darkest level matched (a quarter of white in the short form), and cannot reliably tell the sRGB curve from a 2.2 power law, which differ by a grey level or two at these levels. Its analysis is tested against simulated observers on known curves. On the tested display (a Pro Display XDR on a compressed link), one run of the final script gave grey 186 to 188.5 for half of white from eight of the nine patterns and 190 from single-pixel columns, a best power law of gamma 2.24, and a curve that could not be told from sRGB or from gamma 2.2 (each within 1.4 grey levels rms); the check with the table in use matched. An earlier run, with a version whose arrow keys repeated when held and whose instructions did not say to judge areas rather than edges, gave greys about four levels lower for every pattern, with repeats as tight. That difference between runs is unexplained, so treat one run as good to a few grey levels, not one.

**From 0.5.2.** A uint8 or logical image is stored as it is, in an 8-bit texture, at half the GPU memory, and a uint8 grey or RGBA image in row order is uploaded with no conversion. `SetMouse` (`set_mouse`) moves the cursor to a position in window pixels. The engine commands `Queue` and `WaitScheduled`, which no wrapper exposed, are gone.

```matlab
w = PsychMetal('OpenWindow', struct('bitDepth', 10));
PsychMetal('Linearize', w, 2.2);                      % from a photometer, not a guess
PsychMetal('FillRect', w, 128);                       % half the light of white
PsychMetal('BlendFunction', w, 'add');
PsychMetal('DrawTextures', w, texs, [], rects);       % overlapping textures sum in light
PsychMetal('BlendFunction', w, 'alpha');
PsychMetal('DrawText', w, 'Press a key', [], 100, 255);
PsychMetal('Flip', w);
info = PsychMetal('FlipInfo', w);                     % info.droppedFrames so far; info.dropped once the display has reported
```

```python
w, rect, ifi = pm.open_window(bit_depth=10)
pm.linearize(w, 2.2)
pm.fill_rect(w, 128)
pm.blend_function(w, 'add')
pm.draw_textures(w, texs, None, rects)
pm.blend_function(w, 'alpha')
pm.draw_text(w, 'Press a key', None, 100, 255)
pm.flip(w)
info = pm.flip_info(w)
```

## What changed in 0.5.1

Texture upload is faster: uint8 and logical images are packed through a lookup table, with the same result bit for bit. Two engine commands that no host called, `SettleWindow` and `TimingPolicy`, are gone, and `Diagnostic` no longer reports `pacingWaitMs`. [CHANGELOG.md](CHANGELOG.md) has the details.

Frames can be read back, so a program can check what the GPU rendered.

```matlab
w = PsychMetal('OpenWindow', struct('readback', true));
PsychMetal('FillRect', w, [255 128 0], [10 20 110 70]);
PsychMetal('Flip', w);
image = PsychMetal('GetImage', w);                 % uint8, height x width x 3, RGB
part  = PsychMetal('GetImage', w, [10 20 110 70]); % [left top right bottom], whole pixels
```

```python
w, rect, ifi = pm.open_window(readback=True)
pm.fill_rect(w, [255, 128, 0], [10, 20, 110, 70])
pm.flip(w)
image = pm.get_image(w)                            # uint8, (height, width, 3), RGB
part = pm.get_image(w, [10, 20, 110, 70])
```

`GetImage` returns the frame most recently submitted by `Flip`. The pixels are copied from that frame's own drawable, in the same GPU command buffer, after rendering and before presentation. It is not a second rendering of the draw list, so it cannot disagree with what was presented.

Readback is chosen when the window opens and is off by default. Off, the layer is framebuffer-only and no frame is copied, exactly as in 0.5.0. On, drawables are created readable and every frame is copied once on the GPU, so a readback session is for checking pictures: take no timing from it. `Diagnostic` reports `readbackEnabled`.

Two limits. A full frame is width × height × 3 bytes (61 MB on a 6016×3384 display), and noise does not compress, so pass a rect to keep more than a few frames. And the result is the rendered frame: it says nothing about what the compositor or the panel did with it, for which only a photodiode or a camera will do. Two things it has missed in practice, with every frame reading back exact.

The link may compress the picture. Display Stream Compression is used whenever a mode needs more than the cable carries uncompressed, which includes 5K and 6K panels and high refresh rates. It codes every frame on its own, at a fixed number of bits per pixel, in slices scanned left to right and top to bottom. A stimulus that holds more information than that budget is shown altered: single-pixel noise, dense random dots, any fine high-contrast texture, whether static or new on every frame. How a pixel is altered depends on everything coded before it in its slice, so a change in one region changes how unchanged pixels after it are shown. With static colored noise this appeared as twinkling below a changing patch, as far as the slice boundary. With dynamic noise nothing twinkles, but the noise shown is not the noise computed. Gray single-pixel noise showed no such effect on the same link. To check a stimulus, change one region and watch static texture below it; `PsychMetalDisplayTest` does this, and `LinkInfo` says whether the link has to compress at all.

Liquid-crystal pixels that change on every frame can emit less light than pixels at rest, so a region of dynamic or moving texture is dimmer than the same texture static beside it. A camera shows it; when every region changes on every frame the difference is gone. `PsychMetalDisplayTest` shows a static field beside a changing one.

`PsychMetalReadbackTest` (`python/readback_test.py`) uses it to check the renderer itself: an opaque rectangle and its edges, textures bit for bit, a masked texture over another, global alpha against α·top + (1−α)·bottom, a texture updated on every frame, a partial update, additive blending, linearization by gamma and by table, a line of text, and a 10-bit window read back as 0–1023.

## What changed in 0.5.0

The native core is split into one host-neutral engine and two front ends:

| File | Role |
|---|---|
| `PsychMetalEngine.h` | The engine boundary: one function per native command, plain C++17 |
| `PsychMetalEngine.mm` | The engine: Metal presentation, timing, textures, input |
| `PsychMetalShared.cpp` | Engine parts in plain C++: argument conventions, image packing, CPU noise |
| `PsychMetalMex.cpp` | MATLAB/Octave front end: builds `PsychMetalCore`, which only `PsychMetal.m` calls |
| `PsychMetalPython.cpp` | Python front end: builds `psychmetal._psychmetal` with the plain Python C API |
| `python/psychmetal/` | The Python package: every PsychMetal.m command |

MATLAB and Octave scripts that use `PsychMetal` keep working; `PsychMetalCore` is internal and changed freely. New in every host: `DrawTextures` (`draw_textures` in Python), which draws many textures in one call as Screen's does; `DrawTexture` is its one-texture case. See [DESIGN-0.5.0.md](DESIGN-0.5.0.md) for the boundary rules and threading model.

## Build

Install Apple's command-line build tools. From this directory:

```bash
make octave                                          # PsychMetalCore.mex
make matlab MATLAB_ROOT=/Applications/MATLAB_R2026a.app   # PsychMetalCore.mexmaca64
make python                                          # python/psychmetal/_psychmetal*.so
make python PYTHON=/path/to/python3                  # for a particular Python
make test
```

The included Python extension is for Python 3.14; any other Python needs `make python`, run with that Python, or the pip install below. The extension needs only clang and that Python's headers; numpy is needed at run time. The Python must be an arm64 build.

## MATLAB and Octave

Keep the entire folder together. In a fresh Octave or MATLAB session:

```matlab
addpath(fullfile(getenv('HOME'),'Desktop','PsychMetal','PsychMetal-0.6.0'),'-begin');
which PsychMetalCore
PsychMetalMinimalDemo(10)
```

Adjust the path if installed elsewhere. Add only this folder, **not genpath**: tests/mock contains a deliberately fake core used by regression tests. Restart the host before switching native versions after graphics has been opened.

## Python

```bash
python3 -m venv ~/venvs/psychmetal       # once: a virtual environment
source ~/venvs/psychmetal/bin/activate   # in each new Terminal window
pip install psychmetal                   # from PyPI
pip install ./PsychMetal-0.6.0           # or from a clone of this repository
```

Homebrew's Python refuses packages installed outside a virtual environment, hence the first two lines. pip builds the extension for whichever Python runs it, with Apple's clang. The 0.5.1 wheel installed from PyPI passed the full Python inventory test (169/169) on the tested display, under Python 3.14. Alternatively, put this folder's `python/` on `PYTHONPATH` and use the included Python 3.14 extension, or `make python`.

```python
import psychmetal as pm

with pm.open_window(0, [0, 0, 0]) as (w, rect, ifi):
    pm.fill_rect(w, [255, 0, 0], [100, 100, 300, 300])
    vbl, onset, flip_return, missed, slipped = pm.flip(w)
    pm.wait_secs(1)
```

Each PsychMetal.m command is a function with the snake_case name and the same arguments, order and defaults; MATLAB's `[]` is `None`. Colours run 0–255 by default, as in MATLAB. Deliberate differences: key indices are 0-based (`kb_name('ESCAPE')` is 40, and `key_code[40]` is Escape); several rectangles, dot positions and per-shape colours keep MATLAB's 4xN, 2xN and 3xN/4xN orientation; images are numpy arrays (H, W[, C]) in any memory layout, read without copying; Diagnostic and Resolution(s) return dicts. `help(pm.flip)` and the module docstring describe the details.

`pm.run(experiment)` runs an experiment on the main thread, as Octave's command line does. `pm.run(experiment, threaded=True)` runs it on a worker thread while the main thread services AppKit, as MATLAB does; Ctrl-C then stops at the next frame and still closes the window. The engine releases the GIL while it waits, so other Python threads keep running during `flip` and `wait_secs`.

The `python/` folder has a Python version of every demo and hardware check, run from that folder (`-h` lists each one's arguments; those that open a window take `--threaded`):

| Python | MATLAB/Octave |
|---|---|
| `minimal_demo.py`, `texture_demo.py`, `gabor_demo.py`, `noise_demo.py`, `blob_demo.py`, `mouse_rect_demo.py`, `dot_demo.py`, `kb_demo.py`, `kb_queue_demo.py` | PsychMetalMinimalDemo, …TextureDemo, …GaborDemo, …NoiseDemo, …BlobDemo, …MouseRectDemo, …DotDemo, …KbDemo, …KbQueueDemo |
| `inventory_test.py`, `readback_test.py`, `display_test.py`, `gamma_calibration.py`, `open_ready_test.py`, `motion_test.py`, `hardware_test.py`, `mouse_test.py` | PsychMetalInventoryTest, …ReadbackTest, …DisplayTest, …GammaCalibration, …OpenReadyTest, …MotionTest, …HardwareTest, …MouseTest |

`pm.frame_stats(pm.diagnostic(w), ifi)` is PsychMetalFrameStats. The timing probes (CallerSleepProbe, CompositorProbe, ScheduleSweep, WhenTest and the rest) are MATLAB-only: they measure the engine, which is the same code from every host, and the Psychtoolbox comparisons need Psychtoolbox.

## Drawing and input

Run `PsychMetal('?')` for the supported command list and `PsychMetal('DrawTexture?')` for command details. Check the command's help when porting Screen code; unsupported Screen features do not become available by renaming the function.

Each drawing call costs microseconds of argument handling however much it draws, so draw many items per call: FillRect, FrameRect, FillOval, FrameOval and DrawGabor take 4xN rectangles, DrawDots and DrawLines 2xN points, colors 3xN or 4xN, and `PsychMetal('DrawTextures', w, texs, srcRects, dstRects, angles, filterModes, globalAlphas, modulateColors)` draws many textures, each argument one value for all or one per texture. Drawing colors default to 0–255; `PsychMetal('ColorRange',w,1)` selects 0–1. Floating-point texture arrays use 0–1; uint8 uses 0–255. UpdateTexture updates texture data, all of it or a rect of it, without creating a new public handle. DrawText draws text; FillPoly and FramePoly draw polygons; BlendFunction chooses between covering, adding and replacing; Clip confines drawing to a rect; OpenOffscreenWindow makes a window to draw into and reuse; Linearize makes values linear light. Mouse and keyboard support are part of the main native module; no helper is needed. See [KEYBOARD-QUEUE.md](KEYBOARD-QUEUE.md) for background key transitions, event times and Input Monitoring.

Useful demos: PsychMetalTextureDemo, PsychMetalGaborDemo, PsychMetalNoiseDemo, PsychMetalMouseRectDemo and PsychMetalKbQueueDemo. Optional Psychtoolbox comparison programs are in comparisons/ and require Psychtoolbox.

## Timing and validation

OpenWindow confirms two consecutive background presentations before returning, keeping startup history separate from stimulus history. This removes unconfirmed startup presentations from the first user stimulus in the tested repeated-open cases. It does not eliminate the time required to initialize the window or guarantee every future frame.

Flip timing comes from Metal presentation reports, not a photodiode. Scheduled presentation is quantized by the display refresh. [VALIDATION.md](VALIDATION.md) records the 0.4.3 measurements; timing has not been measured to that standard since, in any host, and the engine has changed in every version since. Repeating it needs the hardware and cannot be done by a test in this folder. A session with linearization on renders two passes per frame and has never been timed. Nor have frames queued with QueueFlip, or the event times of keys and mouse buttons: their design is a best guess until they are measured against a photodiode and a known input signal. [CHANGELOG.md](CHANGELOG.md) lists changes.

For manual hardware checks in a fresh host session:

```matlab
PsychMetalInventoryTest
report = PsychMetalReadbackTest(true);
report = PsychMetalDisplayTest;
report = PsychMetalGammaCalibration;
report = PsychMetalOpenReadyTest;
report = PsychMetalMotionTest(1024);
report = PsychMetalMotionTest(2048);
```

and from Python, in `python/`:

```bash
python3 inventory_test.py
python3 readback_test.py --verbose
python3 display_test.py
python3 gamma_calibration.py
python3 open_ready_test.py
python3 motion_test.py 1024
python3 motion_test.py 2048
```

These open full-screen windows. Motion-test panels must move right together with matching phase, orientation and brightness. Run tests from a writable working directory; reports are saved there. Automated checks do not substitute for visual inspection or physical onset measurement.

## Tests

`make test` (or `python3 tests/run_tests.py`) runs every check that the machine supports and reports what it skipped. Most run anywhere with clang: the engine's internals and boundary, a type check of the Objective-C++ engine, and both front ends end to end against a scripted engine (`tests/mock_engine.cpp`), including the MATLAB wrapper and the inventory, readback and display tests through the real MEX front end under Octave, and every Python demo and hardware check. The scripted engine renders readback frames in software and takes scripted mouse clicks and key presses, so those tests run in full. On a Mac with the binaries built, it also runs the real MEX and Python extension headless and the Metal shader pixel test, which compiles every pipeline and checks the text mask, the linearization pass and the 10-bit frame layout on the GPU. It also checks on the GPU how offscreen windows blend (half alpha, global alpha, overlapping layers, one window through another, copy and additive), with the blend factors the engine uses. That test does not yet cover the clip rect or polygon masks; the readback test (46 checks) does, on a real window.

`tests/workflow-tests.yml` is a GitHub Actions workflow that runs the suite on Linux with Octave, and on macOS builds the real engine against the SDK first. Copy it to `.github/workflows/tests.yml` at the top of the repository to use it.

## Package

The release zip is this folder as tagged, binaries included. `make package` is for a checksummed payload: it verifies RELEASE-MANIFEST.txt and SHA256SUMS and stages the **existing** tested files into dist/PsychMetal, without rebuilding. No manifest has been made for 0.6.0.

## License and attribution

MIT; see [LICENSE](LICENSE). Original attribution in PsychMetalDotDemo.m is retained.
