# PsychMetal 0.5.1

PsychMetal provides native Metal stimulus presentation on Apple Silicon macOS, with an interface resembling supported Psychtoolbox Screen commands, now from MATLAB, Octave and Python. It uses no OpenGL or Vulkan presentation backend. It is experimental research software, not a complete Screen replacement.

**Status.** 0.5.1 adds frame readback to 0.5.0, packs uint8 and logical textures several times faster, and removes two engine commands that nothing called; the presentation and timing path is otherwise that of 0.5.0. Binaries are included for Octave 11.3.0 (Homebrew), MATLAB R2026a and Python 3.14 on Apple silicon; for other versions, rebuild (below). On the tested 6016×3384, 60 Hz display the readback test (15 checks), the hardware test and the inventory test pass in every host: Python (169 checks over 53 commands), Octave and MATLAB (166 over 51 each). 0.4.3's timing validation has not been repeated since, and no version has been validated with a photodiode.

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

The link may compress the picture. Display Stream Compression is used whenever a mode needs more than the cable carries uncompressed, which includes 5K and 6K panels and high refresh rates. It codes every frame on its own, at a fixed number of bits per pixel, in slices scanned left to right and top to bottom. A stimulus that holds more information than that budget is shown altered: single-pixel noise, dense random dots, any fine high-contrast texture, whether static or new on every frame. How a pixel is altered depends on everything coded before it in its slice, so a change in one region changes how unchanged pixels after it are shown. With static colored noise this appeared as twinkling below a changing patch, as far as the slice boundary. With dynamic noise nothing twinkles, but the noise shown is not the noise computed. Gray single-pixel noise showed no such effect on the same link. To check a stimulus, change one region and watch static texture below it.

Liquid-crystal pixels that change on every frame can emit less light than pixels at rest, so a region of dynamic or moving texture is dimmer than the same texture static beside it. A camera shows it; when every region changes on every frame the difference is gone.

`PsychMetalReadbackTest` (`python/readback_test.py`) uses it to check the renderer itself: an opaque rectangle and its edges, textures bit for bit, a masked texture over another, global alpha against α·top + (1−α)·bottom, and a texture updated on every frame.

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
addpath(fullfile(getenv('HOME'),'Desktop','PsychMetal','PsychMetal-0.5.1'),'-begin');
which PsychMetalCore
PsychMetalMinimalDemo(10)
```

Adjust the path if installed elsewhere. Add only this folder, **not genpath**: tests/mock contains a deliberately fake core used by regression tests. Restart the host before switching native versions after graphics has been opened.

## Python

```bash
python3 -m venv ~/venvs/psychmetal       # once: a virtual environment
source ~/venvs/psychmetal/bin/activate   # in each new Terminal window
pip install psychmetal                   # from PyPI
pip install ./PsychMetal-0.5.1           # or from a clone of this repository
```

Homebrew's Python refuses packages installed outside a virtual environment, hence the first two lines. pip builds the extension for whichever Python runs it, with Apple's clang. Under 0.5.0 the pip-built package passed the full Python inventory test on the tested display; a pip build of 0.5.1 has not been tested. Alternatively, put this folder's `python/` on `PYTHONPATH` and use the included Python 3.14 extension, or `make python`.

```python
import psychmetal as pm

w, rect, ifi = pm.open_window(0, [0, 0, 0])
try:
    pm.fill_rect(w, [255, 0, 0], [100, 100, 300, 300])
    vbl, onset, flip_return, missed, slipped = pm.flip(w)
    pm.wait_secs(1)
finally:
    pm.close(w)
```

Each PsychMetal.m command is a function with the snake_case name and the same arguments, order and defaults; MATLAB's `[]` is `None`. Colours run 0–255 by default, as in MATLAB. Deliberate differences: key indices are 0-based (`kb_name('ESCAPE')` is 40, and `key_code[40]` is Escape); several rectangles, dot positions and per-shape colours keep MATLAB's 4xN, 2xN and 3xN/4xN orientation; images are numpy arrays (H, W[, C]) in any memory layout, read without copying; Diagnostic and Resolution(s) return dicts. `help(pm.flip)` and the module docstring describe the details.

`pm.run(experiment)` runs an experiment on the main thread, as Octave's command line does. `pm.run(experiment, threaded=True)` runs it on a worker thread while the main thread services AppKit, as MATLAB does; Ctrl-C then stops at the next frame and still closes the window. The engine releases the GIL while it waits, so other Python threads keep running during `flip` and `wait_secs`.

The `python/` folder has a Python version of every demo and hardware check, run from that folder (`-h` lists each one's arguments; those that open a window take `--threaded`):

| Python | MATLAB/Octave |
|---|---|
| `minimal_demo.py`, `texture_demo.py`, `gabor_demo.py`, `noise_demo.py`, `blob_demo.py`, `mouse_rect_demo.py`, `dot_demo.py`, `kb_demo.py`, `kb_queue_demo.py` | PsychMetalMinimalDemo, …TextureDemo, …GaborDemo, …NoiseDemo, …BlobDemo, …MouseRectDemo, …DotDemo, …KbDemo, …KbQueueDemo |
| `inventory_test.py`, `readback_test.py`, `open_ready_test.py`, `motion_test.py`, `hardware_test.py`, `mouse_test.py` | PsychMetalInventoryTest, …ReadbackTest, …OpenReadyTest, …MotionTest, …HardwareTest, …MouseTest |

`pm.frame_stats(pm.diagnostic(w), ifi)` is PsychMetalFrameStats. The timing probes (CallerSleepProbe, CompositorProbe, ScheduleSweep, WhenTest and the rest) are MATLAB-only: they measure the engine, which is the same code from every host, and the Psychtoolbox comparisons need Psychtoolbox.

## Drawing and input

Run `PsychMetal('?')` for the supported command list and `PsychMetal('DrawTexture?')` for command details. Check the command's help when porting Screen code; unsupported Screen features do not become available by renaming the function.

Each drawing call costs microseconds of argument handling however much it draws, so draw many items per call: FillRect, FrameRect, FillOval, FrameOval and DrawGabor take 4xN rectangles, DrawDots and DrawLines 2xN points, colors 3xN or 4xN, and `PsychMetal('DrawTextures', w, texs, srcRects, dstRects, angles, filterModes, globalAlphas, modulateColors)` draws many textures, each argument one value for all or one per texture. Drawing colors default to 0–255; `PsychMetal('ColorRange',w,1)` selects 0–1. Floating-point texture arrays use 0–1; uint8 uses 0–255. UpdateTexture updates texture data without creating a new public handle. Mouse and keyboard support are part of the main native module; no helper is needed. See [KEYBOARD-QUEUE.md](KEYBOARD-QUEUE.md) for background key transitions and their polling limitations.

Useful demos: PsychMetalTextureDemo, PsychMetalGaborDemo, PsychMetalNoiseDemo, PsychMetalMouseRectDemo and PsychMetalKbQueueDemo. Optional Psychtoolbox comparison programs are in comparisons/ and require Psychtoolbox.

## Timing and validation

OpenWindow confirms two consecutive background presentations before returning, keeping startup history separate from stimulus history. This removes unconfirmed startup presentations from the first user stimulus in the tested repeated-open cases. It does not eliminate the time required to initialize the window or guarantee every future frame.

Flip timing comes from Metal presentation reports, not a photodiode. Scheduled presentation is quantized by the display refresh. [VALIDATION.md](VALIDATION.md) records the 0.4.3 measurements; timing has not been measured to that standard since. [CHANGELOG.md](CHANGELOG.md) lists changes.

For manual hardware checks in a fresh host session:

```matlab
PsychMetalInventoryTest
report = PsychMetalOpenReadyTest;
report = PsychMetalMotionTest(1024);
report = PsychMetalMotionTest(2048);
```

and from Python, in `python/`:

```bash
python3 inventory_test.py
python3 open_ready_test.py
python3 motion_test.py 1024
python3 motion_test.py 2048
```

These open full-screen windows. Motion-test panels must move right together with matching phase, orientation and brightness. Run tests from a writable working directory; reports are saved there. Automated checks do not substitute for visual inspection or physical onset measurement.

## Tests

`make test` (or `python3 tests/run_tests.py`) runs every check that the machine supports and reports what it skipped. Most run anywhere with clang: the engine's internals and boundary, a type check of the Objective-C++ engine, and both front ends end to end against a scripted engine (`tests/mock_engine.cpp`), including the MATLAB wrapper, inventory test and dot demo through the real MEX front end under Octave, and every Python demo and hardware check. On a Mac with the binaries built, it also runs the real MEX and Python extension headless and the Metal shader pixel test.

## Package

The release zip is this folder as tagged, binaries included. `make package` is for a checksummed payload: it verifies RELEASE-MANIFEST.txt and SHA256SUMS and stages the **existing** tested files into dist/PsychMetal, without rebuilding. No manifest has been made for 0.5.1.

## License and attribution

MIT; see [LICENSE](LICENSE). Original attribution in PsychMetalDotDemo.m is retained.
