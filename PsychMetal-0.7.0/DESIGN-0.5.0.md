# PsychMetal 0.5.0 design: one engine, two front ends

Status: built and tested on a Mac through all three front ends (see "First hardware results"). Everything below is checked by the tests in `tests/` except where "Unverified until hardware" says otherwise.

## Goal

Run the same native engine from MATLAB, Octave and Python with identical behavior, validation and timing. Backward compatibility with 0.4.3's native interface is not a goal: `PsychMetalCore` is private to `PsychMetal.m`, and where a simpler or faster design exists it replaces the old one. The user-facing commands stay Screen-like.

## Layout

```
PsychMetalEngine.h     The boundary: plain C++17, standard headers only.
PsychMetalEngine.mm    The engine: Metal, AppKit, CoreGraphics.
PsychMetalShared.cpp   Engine parts in plain C++: scalar conventions, image packing, CPU noise.
PsychMetalInternal.h   Engine-internal declarations shared by the two files above.
PsychMetalMex.cpp      MATLAB/Octave front end -> PsychMetalCore.mexmaca64 / .mex.
PsychMetalPython.cpp   Python front end (plain C API) -> python/psychmetal/_psychmetal*.so.
PsychMetal.m           MATLAB/Octave user API.
python/psychmetal/     Python user API: every PsychMetal.m command, plus run().
```

Each front end links the engine directly; a process loads one front end, so there is no runtime indirection between host and engine.

## The engine

`PsychMetalEngine.mm` holds the presentation, timing, texture, keyboard and input code that was hardware-validated as 0.4.3's `PsychMetalCore.mm`; those internals were not rewritten. The boundary around them is new:

- **Errors** throw `pm::Error{id, message}`. Front ends translate at one boundary, so destructors run on error paths under Octave too.
- **Warnings and module pinning** go through `pm::HostHooks` (`warn`, `pinModule`, `unpinModule`); `pm::shutdown()` runs at exit (`mexAtExit` in MATLAB and Octave, `atexit` in Python).
- **Each command is a `pm::` function** at the end of the engine. Every entry point that touches Objective-C opens an `@autoreleasepool`; without one, autoreleased drawables would accumulate on the caller thread.
- **Images** are read through strided views (`pm::ArrayView`), so MATLAB's column-major arrays and numpy arrays in any layout are read in place. The packing loops, including tiling for large column-major images, live in `PsychMetalShared.cpp`, where the tests run them.
- **Texture drawing is one function**, `drawTextures`, for one texture or many; `DrawTexture` in both front ends is the one-texture case of `DrawTextures`.

## Boundary rules

1. **Validation is shared, not duplicated.** A front end checks only that a host value is the right kind (a real numeric scalar, a dense array), then applies the shared conventions `pm::checkFinite` and `pm::checkUnsigned`, so both hosts word them identically. Ranges, state, capacity and per-element checks are inside the engine functions.
2. **Errors are exceptions**; front ends catch `pm::Error` and `std::exception` at one boundary.
3. **Arrays are strided views** with an element type; unsupported types (int16, float16, complex, sparse) are passed as `Other` so the engine reports its own message.
4. **`PM_BLOCKING`** marks calls that can wait on the display, the GPU, a condition variable, a thread join or the main thread.
5. **One caller thread at a time.** The engine synchronises against its own Metal and keyboard threads only. The Python front end serialises calls with a mutex.
6. **No re-entry.** Engine callbacks never call into the host; warnings are queued by the Python front end and issued after the call.

## Command map

| MEX command | Engine function | B | MEX output packing | psychmetal |
|---|---|---|---|---|
| Version | `version()` |  | string | `version()` |
| PrepareApp | `prepareApp()` | B | none | (open_window) |
| StartupHistory | `startupHistory()` |  | n×6 double | (open_window, diagnostic) |
| ConfirmStartup | `confirmStartup()` | B | n×6 double | (open_window) |
| Open | `openSession(OpenOptions)` | B | six scalars; optional args by position as now | `open_window` |
| Flip | `flip(when)` | B | 1×8 | `flip` |
| FlipStatus | `flipStatus()` |  | 1×3 [confirmed dropped droppedFrames] | `flip_info` |
| PrepareFlip | `prepareFlip()` | B | scalar token | `prepare_flip` |
| PresentNow | `presentNow()` |  | 1×2 | `present_now` |
| SetDisplaySync | `setDisplaySync(on)` | B | none | `set_display_sync` |
| GridAnchor | `gridAnchor()` |  | 1×3 | `grid_anchor`, `get_flip_interval` |
| NextPhase | `nextPhase(after, phase)` |  | scalar | `next_phase` |
| NextRefresh | `nextRefresh(after)` |  | scalar | `next_refresh` |
| WaitToDraw | `waitToDraw(target, budget)` | B | 1×3 | `wait_to_draw` |
| PrefetchDrawable | `setPrefetchDrawable(on)` |  | none | `prefetch_drawable` |
| NoiseValues | `checkNoiseRequest` then `noiseValues(req, out)` |  | H×W or H×W×3 double, shim-allocated | `noise_values`, `draw_noise` |
| GetImage | `checkImageRect` then `getImage(region, out)` or `getImage16(region, out)` | B | H×W×3 uint8, or uint16 for a 10-bit window, shim-allocated | `get_image` |
| Modes | `modes(screen)` |  | n×5, current mode first | `resolution`, `resolutions` |
| SetMode | `setMode(screen, w, h)` |  | none | `resolution` |
| Cursor | `setCursorVisible(show)` |  | none | `hide_cursor`, `show_cursor` |
| Mouse | `mouse()` |  | x, y, 1×3 logical | `get_mouse` |
| SetMouse | `setMouse(x, y)` |  | none | `set_mouse` |
| KbQueueStatus | `kbQueueStatus()` |  | 12-field struct | `kb_queue_status` |
| MouseEvents | `mouseEvents()` |  | n×5 double, dropped scalar | `mouse_events` |
| TouchEvents | `touchEvents()` |  | n×5 double, dropped scalar | `touch_events` |
| KbQueueCreate | `kbQueueCreate(mask, interval)` |  | none | `kb_queue_create` |
| KbQueueRelease | `kbQueueRelease()` | B | none | `kb_queue_release` |
| KbQueueStart | `kbQueueStart()` |  | none | `kb_queue_start` |
| KbQueueStop | `kbQueueStop()` | B | none | `kb_queue_stop` |
| KbQueueFlush | `kbQueueFlush()` |  | none | `kb_queue_flush` |
| KbQueueGetEvents | `kbQueueGetEvents()` |  | n×3 double, dropped scalar | `kb_queue_get_events` |
| KbQueueCheck | `kbQueueCheck()` |  | logical, four 1×256 double | `kb_queue_check` |
| Keys | `keys()` |  | logical, scalar, 1×256 logical, scalar | `kb_check`, `kb_wait` |
| SetBackgroundColor | `setBackgroundColor(r,g,b,a)` |  | none | `background_color` |
| AddShapes | `addShapes(kind, param, rect, color, extra)` |  | none | `fill_rect` … `draw_noise` |
| MakeTexture | `makeTexture(image)` |  | scalar handle | `make_texture` |
| UpdateTexture | `updateTexture(handle, image)`; with left and top, `updateTextureRegion(handle, image, x, y)` | B (region) | none | `update_texture` |
| BlendMode | `setBlendMode(mode)` |  | none | `blend_function` |
| Gamma | `setGamma(r, g, b)` |  | none | `linearize` |
| GammaTable | `setGammaTable(table)` |  | none | `linearize` |
| TextBounds | `textBounds(utf8, font, size)` |  | 1×3 | `text_bounds`, `draw_text` |
| DrawText | `drawText(utf8, font, size, x, y, rgba)` |  | 1×3 | `draw_text` |
| LinkInfo | `linkInfo()` |  | 1×5 | `link_info`, (open_window) |
| Clip | `setClip(rect or none)` |  | none | `clip` |
| OpenOffscreen | `openOffscreen(width, height, rgba)` |  | scalar handle | `open_offscreen_window` |
| SetTarget | `setTarget(handle)`, 0 the window |  | none | every drawing function |
| DrawPolygon | `drawPolygon(points, rgba, pen)` |  | none | `fill_poly`, `frame_poly` |
| QueueFlip | `queueFlip(when)` | B | 1×3 [token pending capacity] | `queue_flip` |
| QueueResults | `queueResults(wait)` | B | n×4 [requested presented status token] | `queue_results` |
| QueueCancel | `queueCancel()` |  | scalar | `queue_cancel` |
| DrawTextures | `drawTextures(handle, src, dst, angle, tint, filter)`, N entries |  | none | `draw_texture`, `draw_textures` |
| CloseTexture | `closeTexture(handle)` |  | none | `close_texture` |
| Wait | `waitUntil(deadline)` | B | scalar | `wait_secs` |
| Now | `now()` |  | scalar | `get_secs` |
| Diagnostic | `diagnostic()` | B | 16-column history, 60-field struct | `diagnostic` |
| Close | `closeSession()` | B | none | `close` |

Two engine functions have no MEX command: `onMainThread()` and `serviceMainRunLoop(seconds)`, used by `psychmetal.run(threaded=True)`.

## Python

The API mirrors PsychMetal.m: each command is a snake_case function with the same arguments, order and defaults, and MATLAB's `[]` is `None`. Choices made for this branch:

- **Key indices are 0-based.** `kb_name('ESCAPE')` is 40, `key_code[40]` is Escape, and the key column of `kb_queue_get_events()` uses the same indices. Hard-coded MATLAB key numbers must drop by one when ported.
- **Colours default to 0–255**, as in MATLAB, with `color_range(w, 1)` for 0–1.
- **Multi-shape arguments keep MATLAB's orientation** (4xN rects, 2xN dots, 3xN/4xN colours), so ported code stays line-for-line.
- **The wrapper is thin and cheap.** Scalars are checked in plain Python; arrays are built directly in the (N, 4) layout the engine reads, with one-of-many arguments broadcast as zero-stride views rather than copied. A one-shape `fill_rect` costs about half what it did in the first port.
- **pip builds it.** `pyproject.toml` describes the package and `setup.py` compiles the three sources into `psychmetal._psychmetal`, adding the `.mm` suffix and ARC for the engine file. `.github/workflows/wheels.yml` at the repository root builds wheels for Python 3.10–3.14 with cibuildwheel and publishes them to PyPI on a version tag, through PyPI's trusted publishing (no stored password).
- **The extension uses the plain Python C API**: clang and Python's headers are the only build dependencies. Arrays arrive through the buffer protocol with their own strides, never copied; results leave through `numpy.frombuffer`, which the package installs as a factory, so no numpy headers are needed.

### Threading

In MATLAB, `mexFunction` runs on the interpreter thread while MATLAB services the AppKit main thread, and the engine's `onMainSync` dispatches to it. Octave's command line instead runs the interpreter on the main thread, where `onMainSync` runs inline and nothing services AppKit between calls; PsychMetal has been validated that way.

`psychmetal.run(fn)` reproduces the Octave arrangement. `psychmetal.run(fn, threaded=True)` reproduces MATLAB's: `fn` runs on a worker thread while the main thread loops in `serviceMainRunLoop`, which dequeues AppKit events and services the main dispatch queue (key events are dropped: the engine polls the keyboard, and an unhandled keyDown would beep). Ctrl-C sets a flag that makes the worker's next `flip`, `get_mouse` or `kb_check` raise `KeyboardInterrupt`, so its own cleanup closes the window.

The Python front end releases the GIL around every engine call. That is required, not an optimisation: in threaded mode a worker inside the engine may be waiting on `dispatch_sync` to the main thread, which must be free to run. It also lets other Python threads run while `flip` blocks. Two consequences for timing-sensitive Python code: a busy background Python thread can delay the return from a blocking call by up to the interpreter's switch interval (5 ms by default), though the engine's timestamps are unaffected; and cyclic garbage collection can pause the caller thread, so `gc.disable()` or `gc.freeze()` around trial blocks is advisable.

## Verification

`python3 tests/run_tests.py` runs everything the machine supports:

| Check | What it establishes |
|---|---|
| `test_engine_header.py` | Header is standalone C++17; every declared function defined once; every MEX command has an engine entry; 60 Diagnostic fields in the same order in header, MEX and Python; 17 history columns; identifiers only through constants |
| `test_typecheck.py` | The Objective-C++ engine type-checks against the macOS SDK, or elsewhere against `tests/macstubs` |
| `test_native_dispatch.py` | The real image packer: every layout (column-major, row-major, transposed, reversed, strided) packs identically on the linear and tiled paths; `drawTextures` queues one item per entry as given, keeps texture snapshots, and queues nothing when any entry is invalid |
| `test_mouse_dispatch.py`, `test_secure_input.py`, `test_startup_ready.py`, `test_timing_target.py` | Regression tests of engine internals: mouse coordinates and buttons, secure input, startup confirmation, deadline handling |
| `test_noise_layout.py`, `test_mask_cache.py` | `noiseValues` writes identical noise into every array layout; the cache of rendered text and polygons gives up the masks wanted longest ago, and measuring text renders nothing |
| `test_flip_status.py`, `test_queue_results.py`, `test_render_failure.py` | The engine's own functions, extracted: a drop reported after Flip has returned is counted; a frame still pending after a timed-out wait is reported again with its outcome; a GPU failure in rendering that is not presented fails the session and its frame |
| `test_frontends.py` | Both front ends, built against a scripted engine: PsychMetal.m through the real MEX front end under Octave (every command family, messages and identifiers, column-major images untransposed), PsychMetalInventoryTest and the dot demo's sprite path; the psychmetal package through the real Python front end (61 checks, including every memory layout, exact texture-draw arguments, GIL release during flip, both threading modes and Ctrl-C) |
| `test_python_demos.py` | Every Python demo and hardware check end to end against the scripted engine, each stopped by its own click or deadline: frame counts, texture uploads and draws, Gabor phase steps, noise reconstruction, four repeated opens, the full inventory test with its coverage check |
| `test_headless.m`, `test_python_headless.py` | The real built MEX and Python extension without a window (Mac only) |

### First hardware results (Python front end)

A timing diagnostic (not distributed) on macOS 27.2, Python 3.14, a 6016x3384 display at 60 Hz, captured, three drawables, before the texture and wrapper changes above:

- Threaded mode, main-thread mode, and main-thread mode servicing AppKit after every flip all present every frame with a confirmed time; flip's presentation callbacks do not need the main run loop serviced.
- 30 s still + 30 s moving-mouse halves, main thread, run loop never serviced: CPU work per frame (mouse, keys, four draw calls) median 0.8 ms still and 0.55 ms moving, max 1.35 ms, flat across the run. Servicing the run loop every frame gives the same work times and adds 0.1–0.6 ms (max 5 ms) of servicing. An unserviced event queue does not slow the loop over time.
- One 2-refresh interval in 3,600 frames (main thread, not serviced), with normal CPU work around it: the drawable wait before the following flip took two refreshes. Not attributable to the front end.
- In the loop, each call costs about 10x its isolated microbenchmark (e.g. `fill_rect` 0.25–0.3 ms vs 0.017 ms), and the still half costs more than the moving half; both point to CPU frequency scaling while the loop idles in flip, not to per-call overhead.

On the same display after the texture and wrapper changes: `make octave && make python && make test` passed every check, including the Mac-only real-extension, keyboard-queue and Metal shader tests; `python/inventory_test.py` passed 156/156 checks across 52 commands; `python/texture_demo.py` drew 5 textures per frame from 2 uploads at 59.94 presentations/s with one late frame in 1,200. `make matlab` compiled against MATLAB R2026a's `mex.h` with no warnings, and PsychMetalInventoryTest passed 153/153 checks across 50 commands in both MATLAB and Octave 11.3.0 on the real engine.

### Unverified until hardware

- Everything the timing work established for 0.4.3 (VALIDATION.md), rerun under MATLAB, Octave and Python.
- The remaining demos and hardware checks on a real display, in each host.
- Frame timing under MATLAB and Octave with the 0.5.0 engine. By construction it matches 0.4.3: the same engine code runs, and per-call overhead is microseconds.

## Invariants the engine must keep

- **Draw-list state belongs to the caller thread.** `drawList`, `drawCount` and `drawTextureRefs` are appended by `addShapes` and `drawTextures` and consumed by `encodeShapes` inside `flip`/`queueFrame`/`prepareFlip`, on the same thread. The capacity checks before the lock are correct only under that invariant, which the one-caller rule guarantees.
- **Texture lifetime is reference-counted across the GPU boundary.** `encodeShapes` captures the frame's texture references in the command buffer's completion handler, then resets `drawTextureRefs[0..n)`. The texture pool's reuse test counts owners, so no new long-lived reference to a texture may be added outside `userTextures`, `texturePools` and the per-frame capture.
- **Only the current target has draws waiting.** With an offscreen window as the target, draw-list items from `targetBase` on are its; `flushTarget` renders and removes them before the target changes and before any frame is encoded, so `encodeFrame` only ever sees the window's own draws.
- **Queued frames are shown in order, by one thread.** `presenterMain` is the only code that presents a queued frame. `Flip` and `PrepareFlip` must not present while the queue holds frames or the last one handed over is unconfirmed (`waitQueueIdleLocked`).
- **Event taps run on their own run-loop thread** and touch only the keyboard queue (its own lock) and the mouse buffer (`tapLock`), never `lock`.
- **Main-thread work goes through `onMainSync`**, never while holding `lock`.
- **Every entry point that touches Objective-C opens an `@autoreleasepool`.**
- **Names inside `pm::` functions resolve to `pm::` first.** Internals whose names match a `pm::` function (`prepareApp`, `confirmStartup`, `prepareFlip`, `presentNow`, `waitScheduled`) are called with `::`. The per-frame texture array is `drawTextureRefs`, not `drawTextures`, for the same reason.
- **Never add the package folder with `-I`.** On a case-insensitive disk its `VERSION` file answers the C++ library's `#include <version>`. Sources include each other with quotes; tests use `-iquote`.
