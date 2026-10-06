# Changelog

## 0.6.0 — 2026-10-06

Linearization, 10-bit frames, additive blending, text, partial texture updates, a report of the display link, a display test, dropped frames reported rather than raised; then offscreen windows, polygons, a clip rect, multi-line text, frames queued ahead and input timed by its events; then four corrections from a review of the source and three small changes. Includes the unreleased 0.5.2. Built against the macOS 27.2 SDK without compiler warnings for Octave 11.3.0, MATLAB R2026a and Python 3.14. On a 6016×3384 display the suite with its Metal shader test passes, and from Python and from Octave the readback test (46 checks) and the inventory test (220 checks over 68 commands from Python, 218 over 66 from Octave); queued frames were reported shown at the refresh asked for from both hosts, and key events are timed with Input Monitoring allowed. MATLAB builds; its tests have run only against the scripted engine. No timing in this version has been measured with a photodiode or a known input signal.

### Changes

- Corrected: a partly transparent offscreen window was drawn too dark. What it holds is colour multiplied by alpha, and drawing it multiplied by alpha again: half-alpha white drawn through a transparent offscreen window came out a quarter white. An offscreen window is now drawn as what it is, so drawing it gives what the draws made into it would have given directly, soft edges and overlaps included; a global alpha or a tint's alpha applies to all of it; the colour it is opened with and a colour copied into it are stored the same way. An opaque offscreen window is unchanged, except drawn with `'copy'` at a global alpha below 1, where its colour is now scaled by that alpha too. How each blend mode's factors depend on source and target is one function, `pm::internal::blendFor`, used by the engine, the scripted engine and the Metal test. Engine: `PM_TARGET_OFFSCREEN`, texture pipelines by kind of source, `tfmain` mono mode 3.
- Corrected: a GPU failure in a command buffer that renders without presenting (a queued frame's store, an offscreen window's draws or first contents) went unseen, and a queued frame whose store was never rendered could be presented and reported shown. Such a failure now fails the session, as one in a presented frame does: the presenter waits for a frame's store to be rendered and does not show one that failed, the frame is reported with status 3 (which a cancellation no longer overwrites), and the next `Flip` or `QueueFlip` raises. A failure in an offscreen window's draws is learned after the `Flip` that used them has been submitted, so it is the next one that raises. Engine: `renderFinished`, `watchRender`, `storeState`.
- Corrected: `droppedFrames` missed drops. Without `waitForConfirm`, the default, `Flip` returns before the display has reported on its frame, so the wrappers' count, taken from what `Flip` returned, stayed at zero. `FlipInfo` now asks the engine when it is called: `confirmed` and `dropped` are what the display has reported of the last flip's frame so far (both false until it has, about a refresh later, by when a loop has flipped again), and `droppedFrames`, the one to read after a trial, is the engine's count of every frame reported never shown, queued frames included. `Diagnostic`'s `droppedFrames` is the same count. Engine: `flipStatus`; `FlipResult` loses `dropped`, and `PsychMetalCore('Flip')` returns eight values again.
- Corrected: `QueueResults`, after a wait that timed out, reported the frames still pending and then forgot them, so their outcomes could never be read. A frame is now forgotten only once its outcome has been reported: one still pending after the wait is reported as pending and again by the next call, until ten seconds after its time, when it is given up on.
- Tests for those four: `tests/test_flip_status.py`, `tests/test_queue_results.py` and `tests/test_render_failure.py` run the engine's own functions; `PsychMetalReadbackTest` and `readback_test.py` go on to 46 checks (overlapping, soft-edged, partly transparent draws through an offscreen window against the same draws made directly; half-alpha white; global alpha; one offscreen window through another; a colour copied in or given at opening); `tests/test_metal.mm` draws through offscreen targets on the GPU with the engine's blend factors. The scripted engine blends by those factors too, and its display now reports on a frame most of a refresh after `Flip` has returned, as a Mac's does, unless the window waits.
- Text and polygon renderings are kept differently. When the 256 masks or 256 MB are full, the ones wanted longest ago make way one at a time, where everything used to be thrown out together: text drawn on every frame stays while a counter or a clock that changes passes through. `TextBounds` no longer renders what it measures: a line that has been drawn is known by its rendering, and any other is only laid out, so wrapping a paragraph no longer makes a texture for each of its words. Engine: `findMask`, `layoutText`. Built on the Mac; the Python inventory test, which measures a line before and after drawing it, passes on the display.
- `noise_values` (`NoiseValues`) writes along the rows of an array laid out by rows, as numpy's are, and along the columns of one laid out by columns, as MATLAB's are; it used to go by columns always. The values are the same. A 2048×2048 colour array by rows, from Python, fills in 19 ms on the Mac Studio where it took 35; on the x86 test machine the gain is about a tenth, and an array by columns is unchanged.
- Python: what `open_window` returns is still the tuple `(w, rect, ifi)` and is now also a context manager: `with pm.open_window(...) as (w, rect, ifi):` closes the window and shows the cursor when the block ends, however it ends. MATLAB and Octave are unchanged; `onCleanup` or `try`/`catch` does this there.
- Tests for those three: `tests/test_mask_cache.py` and `tests/test_noise_layout.py` run the engine's own functions; both inventory tests check that a line measures the same before it is drawn, as it is drawn, and after.
- A frame that was submitted but never shown no longer raises. `Flip` returns its projected time; new `FlipInfo` (`flip_info`) reports `confirmed`, `dropped`, `slipped`, `queueMs` and `flipMs` for the last flip and `flips`, `droppedFrames` and `slipFlips` for the session. `Diagnostic` gains `droppedFrames`. A GPU failure, no drawable and a confirmation timeout still raise.
- New `Linearize` (`linearize`): a display gamma (one value or `[r g b]`, 0.05 to 20), an N×3 table of display values for N evenly spaced linear values (N 2 to 4096, interpolated), or empty to turn it off. With it on, the frame is drawn and blended in an RGBA16Float target and a second pass writes the display values, so blending is linear in light. The target and its pipelines are made the first time it is turned on. Engine: `setGamma`, `setGammaTable`; shader functions `evmain`, `efmain`. The table is held as 32-bit floats and interpolated in the shader.
- New `OpenWindow` option `bitDepth` (`bit_depth`), 8 or 10. A 10-bit window's drawable is BGR10A2Unorm, and `GetImage` returns uint16 0–1023. Engine: `OpenOptions::bitDepth`, `getImage16`, `MutableWordView`, `ImageRegion::bits`.
- New `BlendFunction` (`blend_function`), `'alpha'` or `'add'`, returning the old mode. The mode is recorded with each draw. Engine: `setBlendMode`; one pipeline per target and blend.
- New `DrawText` and `TextBounds` (`draw_text`, `text_bounds`): one line, rendered by CoreText into a coverage mask, kept in an 8-bit texture and drawn as a texture whose value is its alpha. Up to 64 rendered lines are kept. Engine: `drawText`, `textBounds`; `tfmain` mono mode 2. Links CoreText.
- `UpdateTexture` (`update_texture`) takes an optional rect and then replaces that part of the texture in place. It waits up to two seconds for frames in flight that draw the texture, and refuses one that is queued. Engine: `updateTextureRegion`.
- New `LinkInfo` (`link_info`): lanes, lane rate and payload of the DisplayPort link, from the IO registry, the bit rate the window needs, and whether the link must be compressing. `OpenWindow` prints two lines when it must. Engine: `linkInfo`. Links IOKit.
- New `OpenOffscreenWindow` (`open_offscreen_window`): an RGBA16Float render target in a texture slot, named by a texture handle that every drawing command accepts as its window. Only the current target has draws waiting; they are rendered into it, in a command buffer of their own, when the target changes or a frame is made. `Rect`, `WindowSize` and `Close` accept the handle. Texture handles now start above the window handle, so no number names both. Refused: drawing it into itself, `UpdateTexture` on it, and drawing into it while the window has an unflipped draw of it. Engine: `openOffscreen`, `setTarget`, `flushTarget`.
- New `FillPoly` and `FramePoly` (`fill_poly`, `frame_poly`): 3 to 4096 points, rasterized by CoreGraphics into an 8-bit coverage mask (even-odd fill, or a mitred stroke) and drawn as text is. Masks are kept by shape, to 256 masks or 256 MB; points are rounded to 1/256 pixel. Engine: `drawPolygon`.
- New `Clip` (`clip`): a rect recorded with each draw and applied as a scissor rect. `BlendFunction` gains `'copy'`. Engine: `setClip`, `PM_BLEND_COPY`.
- `DrawText` and `TextBounds` take newlines and a wrap width in pixels. The layout is the wrappers': lines are 1.3 × size apart, each line is one engine `DrawText`, and the last 16 layouts are kept.
- New `QueueFlip`, `QueueResults`, `QueueCancel` (`queue_flip`, `queue_results`, `queue_cancel`). A queued frame is rendered at once into a texture of the drawable's format; a presenter thread at user-interactive priority takes a drawable three refreshes before the frame's time, copies the texture into it and presents it at the time less half a refresh. Frames are shown in order and none is skipped. Up to 1 GiB of frames (2 to 64). `Flip` waits for the queue; `PrepareFlip` refuses while it is not empty. Status 5 is a cancelled frame. `GetImage` reads a queued frame as soon as it is rendered. Timing unvalidated.
- The keyboard queue takes key times from a listen-only event tap on a thread of its own where the system allows it (Input Monitoring), and polls otherwise, warning once (`PsychMetal:InputMonitoring`). Polling continues beside the tap and records what no event reported within 20 ms. `KbQueueStatus` gains `eventTimestamps`, `eventStamped`, `pollStamped` and `maxEventDelayMs`. The system is asked for the permission only when no window is open. Engine: `PMKeyboardQueue::post`, `setExternal`.
- New `MouseEvents` (`mouse_events`): button presses and releases with the events' times, from a second tap, in a 4096-event buffer. The first call starts it.
- The shape and mask fragment shaders discard fragments with no coverage, so a 'copy' draw of a round or soft shape leaves what is outside it alone.
- `PsychMetalReadbackTest` and `readback_test.py` go on to 41 checks: an offscreen window drawn, kept and cleared, the clip rect, a filled and an outlined polygon, and three queued frames. Both inventory tests cover the new commands.
- New `PsychMetalGammaCalibration.m` and `python/gamma_calibration.py`: the display's response by halftone matching. The short form, the default, is four matches: half of white against 4-pixel rows and columns, then a quarter and three quarters. The long form (`full`) matches half of white against nine patterns (rows and columns 1 to 8 pixels thick, a checkerboard) as a test that fine patterns emit their mean light, then seven levels by halving, each twice. The value is hidden while matching, each key press is one level, and both report the best power law and the misfit of gamma 2.2 and of the sRGB curve in grey levels; a 256×3 table for `Linearize` that follows the points; grey or each of red, green and blue; and a check of half of white with the table in use. The analysis is tested with simulated observers on displays of gamma 1.8, 2.4 and sRGB. On the tested display one run gave half of white at grey 186 to 188.5 from eight of nine patterns (190 from single-pixel columns) and a best power law of 2.24, not distinguishable from sRGB; an earlier run of an earlier version gave values about four grey levels lower throughout, unexplained.A first run on the tested display found fine rows and columns matching different greys (182 and 186.5), which is why the pattern comparison was extended to coarse patterns.
- New `PsychMetalDisplayTest.m` and `python/display_test.py`: the link report, static noise beside changing noise for compression, asked for colour and for grey, a static field beside a changing one for pixel response, and a gamma match by eye. Each asks what was seen and reports what follows.
- `PsychMetalReadbackTest` and `readback_test.py` go from 15 to 32 checks: a partial update, additive blending, linearization by gamma and by table, half-alpha white over black in linear light, text position, orientation and colour, and a 10-bit window. Both inventory tests cover the new commands and their misuse.
- `Diagnostic` gains `bitDepth` and `blendFunction` in the wrappers' summary.
- From 0.5.2: uint8 and logical images are stored in 8-bit normalised textures (R8Unorm for grey, RGBA8Unorm otherwise) instead of half-float ones, and a uint8 grey or RGBA image whose rows follow one another in memory is uploaded in place. A byte v is still v / 255. `UpdateTexture` may change a texture between the two kinds. Engine: `packBytes` for uint8 and logical, `packImage` for float.
- From 0.5.2: new `SetMouse` (`set_mouse`), which moves the cursor to a position in window pixels. Engine: `setMouse`.
- From 0.5.2: removed the engine commands `Queue` and `WaitScheduled` (`queueFrame`, `waitScheduled`, `ScheduleResult`), which no wrapper exposed. `PsychMetalCore('SetMode')` returns nothing.
- MATLAB text is converted to UTF-8 with `mxArrayToUTF8String`; Octave's is UTF-8 already.
- Tests: the scripted engine draws additive blending, linearization, 10-bit frames and a block per character of text, reports a scripted link (`PM_MOCK_LINK`), drops scripted frames (`PM_MOCK_DROP`) and presses scripted keys (`PM_MOCK_KEYS`). `tests/test_metal.mm` compiles every pipeline for 8-bit, 10-bit and linear targets and checks the text mask, the linearization pass and the 10-bit word layout on the GPU. `tests/workflow-tests.yml` is a CI workflow for the suite: Linux with Octave, and macOS building the real engine.

## 0.5.1 — 2026-10-04

Frame readback, a faster texture upload, and two unused commands removed. Built for Python, Octave and MATLAB on Apple silicon (macOS SDK 27.2). Run on a GPU from Python 3.14, Octave 11.3.0 and MATLAB R2026a on a 6016×3384 display: the readback test (15 checks, identical figures in all three hosts), the hardware test and the inventory test (169 checks over 53 commands in Python, 166 over 51 in Octave and in MATLAB) pass.

### Changes

- New `GetImage` (`get_image`): the frame most recently submitted by `Flip`, as uint8 height × width × 3 RGB, optionally a `[left top right bottom]` rect of it in whole pixels. The pixels are copied from the frame's own drawable in the same command buffer, after the render pass and before the present, not rendered a second time.
- New `OpenWindow` option `readback` (`open_window(readback=True)`), by name only, off by default. Off, the layer is framebuffer-only and nothing is copied, as before. On, drawables are readable and each frame is copied once on the GPU; such a session is for checking pictures, not timing. `Diagnostic` gains `readbackEnabled`.
- `GetImage` refuses a window opened without readback, a rect that is fractional, empty or outside the window, and a last frame that was never copied (no drawable, or a failed encoding) rather than returning an older one.
- Engine: `OpenOptions::readback`, `checkImageRect`, `getImage` and `MutableByteView` in `PsychMetalEngine.h`. `PsychMetalCore('Open')` takes `readback` after `refreshHz`, and an empty `refreshHz` now means no override.
- New `PsychMetalReadbackTest.m` and `python/readback_test.py`: an opaque rectangle and its edges, uint8 and float textures, a masked texture over another, global alpha against α·top + (1−α)·bottom, and a texture updated on every frame, each compared with the frame read back.
- Both inventory tests cover `GetImage` and its misuse.
- Tests: the scripted engine has a small software renderer for readback sessions (background, FillRect, unrotated nearest-sampled textures, source-over blending into 8 bits), so the readback checks and the front ends' array layout are exercised without a GPU. `tests/macstubs` declares the blit and `getBytes` calls the engine now uses.
- Texture upload: uint8 and logical images are converted through a 256-entry table instead of one double-precision conversion per element. The packed half floats are bit for bit what they were; on the x86 test machine a uint8 image packs 5 to 13 times faster (not yet timed on Apple silicon). Float images are unchanged. The two copies of the packing loop are one.
- Engine internals, no change in behaviour intended: the three copies of the percentile window (lead, pipeline, GPU) are one `PMEstimate`; the two pipeline and two sampler set-ups are `makePipeline` and `makeSampler`; `Modes` and `SetMode` share `copyAllModes`; `Close` and `Diagnostic` share one drain; the frame is encoded from the draw list in place instead of from a 1 MB copy of it; `presentNow` returns its result instead of filling two pointers; the capture request is an argument, not a global; the id ceiling is `pm::kMaxId` only. Type-checked and run through the GPU-free tests.
- Removed two engine commands that nothing called, in any host: `SettleWindow` and `TimingPolicy`. The timing policy was therefore always 0, so the code for policies 1 and 2 (bounded submissions and an extra settle at startup) is gone with it. `Diagnostic` loses what only they produced: the `timingPolicy` summary field (60 fields again) and the pacing-wait history column (16 columns), which was `pacingWaitMs` in PsychMetal.m and psychmetal. `Queue` and `WaitScheduled` stay: no wrapper exposes them, but they are the only way to submit a frame without waiting for it.

## 0.5.0 — 2026-09-30

Python support, through one native engine shared by every host. Includes Octave 11.3.0, MATLAB R2026a and Python 3.14 binaries; the inventory test passes in all three hosts on the tested display, and 0.4.3's timing validation has not yet been repeated. The native interface (`PsychMetalCore`) is internal and was changed without regard to 0.4.3; scripts that call `PsychMetal` keep working.

### Changes

- Split the native core into a host-neutral engine (`PsychMetalEngine.h`, `PsychMetalEngine.mm`, `PsychMetalShared.cpp`) and two front ends: `PsychMetalMex.cpp` for MATLAB and Octave, and `PsychMetalPython.cpp` for Python. The hardware-validated presentation, timing, texture and input internals are unchanged.
- Python: new `psychmetal` package with every PsychMetal.m command as a snake_case function, colours 0–255 by default, 0-based key indices, numpy images in any memory layout read without copying, `frame_stats`, and `run(fn, threaded=False|True)` for Octave-style or MATLAB-style threading. The extension builds with clang and Python's headers only (`make python`). Drawing arguments are built directly in the engine's layout: a one-shape call costs about half what it did in the first port, and a 50-texture `draw_textures` about 60%.
- New `DrawTextures` (`draw_textures`), as Screen's: many textures in one call, each argument one value for every draw or one per draw (rectangles 4xN, colours 3xN/4xN), drawn in order; the engine checks every entry before queuing any. `DrawTexture` is now its one-texture case at every layer, so the engine has one texture-drawing function and the native `DrawTexture` command is gone.
- `DrawTexture` no longer has a special message for a colour at argument 6 (the pre-0.4.0 position); it is rejected as an invalid filter mode.
- `pip install` support (`pyproject.toml`, `setup.py`): pip compiles the extension for the Python that runs it. A GitHub Actions workflow builds wheels for Python 3.10–3.14 on Apple silicon and publishes them to PyPI as `psychmetal` when a version tag is pushed. 0.5.0 is on PyPI: https://pypi.org/project/psychmetal/.
- Python versions of every demo and hardware check (`python/*_demo.py`, `inventory_test.py`, `open_ready_test.py`, `motion_test.py`, `hardware_test.py`, `mouse_test.py`). The Python inventory test derives its command list from the package and fails if any command goes unexercised.
- PsychMetalDotDemo draws its sprites, and PsychMetalTextureDemo its tinted copies, with one `DrawTextures` call.
- PsychMetalInventoryTest covers `DrawTextures`; its static scan for pre-0.4.0 `DrawTexture` calls and its `UseOpenGL` check are gone. Its two warning checks failed under Octave, which does not record a disabled warning in `lastwarn`; under Octave the warnings now stay on.
- The engine reports errors as C++ exceptions, so destructors run on error paths under Octave, and opens an autorelease pool at every entry point.
- Tests: boundary consistency (header, MEX and Python agree); an Objective-C++ type check that runs without the macOS SDK; both front ends end to end against a scripted engine, including PsychMetal.m, PsychMetalInventoryTest and the dot demo through the real MEX front end under Octave, and every Python demo and hardware check; the image packer on every memory layout and the tiled path; headless checks of the real MEX and Python extension on a Mac. `tests/run_tests.py` reports what it skips.
- Makefile: `make python`; the MATLAB and Octave targets build from the three engine and front-end sources.

## 0.4.3 — 2026-09-17

Native Metal stimulus presentation for Apple Silicon, with Octave and MATLAB binaries and source. This release includes the 0.4.1 demo/signature corrections and the 0.4.2 mouse and background keyboard queue fixes; their changelog entries are retained.

### Changes

- OpenWindow confirms two consecutive presentations of the requested background before returning. Initialization has bounded confirmation attempts, cleans up on failure, and records startup history separately from stimulus frames.
- Preserve the first scheduled deadline before refresh-grid calibration; retain the existing default pacing policy.
- Add UpdateTexture and direct native image packing for uint8, single, double and logical arrays. Grayscale uses a single-channel texture; large images use tiled packing. Reusable texture storage is protected until GPU completion.
- Fix OpenWindow option indexing, resolution dispatch, native input validation, draw-list overflow handling and a DrawTexture error-path deadlock.
- Retain queued texture snapshots, use unique handles, fence shared drawing buffers and reject callbacks from earlier sessions. Fix close-after-prepare and reopen behavior.
- Consolidate Flip into one native call, report submission/GPU/confirmation failures explicitly, and separate drawable, encoding and prefetch measurements.
- Keep canonical Metal shader source separate and correct output-alpha blending.
- Make keyboard waits interruptible, add KbQueueStatus, define queue Flush as a scan barrier, and avoid owner-PID lookup in KbCheck's Secure Input check.
- Improve inventory and native regression checks; include motion and repeated-open acceptance tests. Optional Psychtoolbox comparisons live in comparisons/.

### Compatibility and validation

Finite floating-point texture inputs use 0–1; uint8 inputs use 0–255. Noise rectangles require integers. Geometry diagnostic fields were renamed and handles are opaque and not recycled. Restart Octave/MATLAB to switch native builds after opening a graphics window: the MEX remains pinned to protect asynchronous callbacks.

On the tested 6016×3384, 60 Hz display in Octave, the final binary passed 10/10 repeated-open/first-stimulus checks and all 151 inventory checks across 49 public commands. Startup confirmation took 3–5 attempts (88–115 ms); whole OpenWindow calls took about 1.38–1.47 s. Earlier optimization-stage throughput tests are recorded separately in VALIDATION.md.

The MATLAB binary was built but has not received equivalent hardware testing. Timing is based on Metal presentation reports; no photodiode validation or universal frame-rate guarantee is claimed. The supplied Octave binary links Homebrew Octave 11.3.0; rebuild for a different installation if required.

## 0.4.2 — 2026-09-15

- Add native background keyboard queue commands: Create, Start, Stop, Flush,
  Release, Check and GetEvents. Preserve KbCheck, share its HID mapping and
  sided-modifier handling, retain timestamped transitions across host work,
  report bounded FIFO overflow, and release the worker on Close/unload.
- Add PsychMetalKbQueueDemo and native worker/lifecycle regression tests.
  Detection timestamps have polling resolution, not hardware event timing.
- Exclude standalone k-space programs and images from the library release.

- Replace cached AppKit mouse polling in the main MEX with CoreGraphics
  session button state and global cursor position. Preserve the existing
  logical 1x3 [left right middle] API and instantaneous polling semantics.
- Convert coordinates using the actual Metal render dimensions, not
  CGDisplayPixelsWide/High, which can differ in scaled Retina modes.
- Release the temporary CGEvent on every successful read; fail explicitly
  if no window, display geometry, or mouse event is available.
- Add PsychMetalMouseTest for manual button/position validation and a
  display-free regression test of the actual native Mouse dispatch.
- Correct stale mouse-demo documentation and its near-black crosshair color.
- Rebuild Octave and MATLAB Apple Silicon MEX binaries.


## 0.4.1 — 2026-08-27

### Fixed

- **Three call sites were never updated when `DrawTexture`'s arguments moved.**
  0.4.0 put `filterMode` at 6, `globalAlpha` at 7 and `modulateColor` at 8, to
  match Screen. `PsychMetalTextureDemo` still passed a colour at argument 6
  twice and `PsychMetalDotDemo` once, so each raised an error about filter
  modes on the first frame that drew a texture. The two texture-demo colours
  were also still on the 0-1 convention, so they would have drawn near-black
  even in the right slot.

  It was found by running the demo, which is the part worth recording. The
  inventory test calls `DrawTexture` directly and never runs a demo, and all
  three copies of the documented signature — the dispatch comment, the general
  help and the per-command topic — still said `[, tint]` at 6. A help audit
  compared the general help against the topic help and passed, because they
  were wrong in the same way. Agreement between two documents is not
  correctness; both have to be checked against the code that reads the
  arguments.

  Three changes, one per layer. The signature is corrected in all three places
  it appears. A colour at argument 6 now raises an error that names the cause —
  pre-0.4.0 code, `modulateColor` is argument 8, here is the corrected call —
  rather than complaining about filter modes and sending the reader off to
  think about filtering. And `PsychMetalInventoryTest` statically scans every
  `PsychMetal*.m` file for the old shape, since a demo's call sites are
  otherwise checked only by somebody launching the demo.

  `PsychMetalCore.mm` is untouched. 0.4.1 is the wrapper, two demos and the
  test.

## 0.4.0 — 2026-08-25

The design settles here: PsychMetal replaces `Screen` rather than coexisting
with it. It keeps `Screen`'s **argument formats**, so that replacing `Screen(`
with `PsychMetal(` in existing code is meant to work, and copies none of its
**implementation**, so that nothing is shaped by how OpenGL would have done it.

### Added

- **`KbCheck`, `KbWait` and `KbName`, without PsychHID.** macOS merges every
  attached keyboard into one system-wide state before any of this is visible —
  built-in, USB and Bluetooth arrive identical and unlabelled — so
  `CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, ...)` reads all of
  them with no device enumeration and no per-device quirk handling. `keyCode`
  is indexed by HID usage code, which is what Psychtoolbox returns and what
  `KbName`'s numbers mean, so a ported script's constants survive; the
  virtual-keycode-to-usage table exists precisely so they do, since reporting
  Mac virtual codes would have been easier and would have silently shifted
  every `KbName` constant onto a neighbouring key.

  Two limits are documented rather than papered over. There is no
  `deviceNumber` and there cannot be one: the merge that makes this easy is
  also what destroys the per-device information, so a response box that does
  not present as a keyboard stays invisible and stays PsychHID's job. And the
  timestamp is the moment of the **poll**, not of the keypress, so an RT
  measured this way is quantised to the polling interval, with a Bluetooth
  keyboard adding tens of milliseconds of latency and jitter underneath. It is
  for advancing a trial, not for measuring one.

  Left and right modifiers are reported separately, which the obvious
  implementation does not do. `CGEventSourceKeyState` collapses each pair onto
  its left-hand virtual keycode — press the right shift and `0x38` reads down
  while `0x3C` stays up — so a first version reported both shifts as
  `LeftShift`. Left and right shift are a standard pair of 2AFC response keys,
  so that is not cosmetic: both responses would have been identical and
  `keyCode(229)` would never have fired at all, in an experiment that otherwise
  looked like it was running. The sidedness is recovered from the
  device-dependent flag bits, with the collapsed keycodes kept as a fallback
  for any keyboard that does not report sides.

  Secure event input is detected and warned about once per session. It is the
  one failure that is otherwise invisible: while any process holds it — a
  password field, a password manager — every key reads up, no error is raised,
  and an experiment quietly records nothing.
- **`DrawNoise`'s `spread` now follows `ColorRange`, like its mean.** It was in
  raw shader units while the mean was scaled, so at range 255 a caller writing
  `mean 128, spread 128` — the obvious way to say "black to white" — would have
  got a spread 255 times too wide. The two are added together in the shader, so
  a spread in different units from its mean is silently the wrong contrast.
  `NoiseValues` reports on the `ColorRange` too, because those are the values
  that were shown.
- **`globalAlpha` is clamped.** It was scaled by the range but never bounded, so
  a value above it reached the blend unclamped: the fragment shader's `saturate`
  applies to the coverage, not to the product with alpha.
- **`ColorRange`, opening at 255 exactly as Screen's does.** Colours were 0-1,
  which made a ported script render every stimulus at 1/255 of its intended
  brightness — silently, because 255 and 128 both clamp to white.
  `PsychMetal('ColorRange', w, 1)` gives the 0-1 convention that
  `PsychDefaultSetup(2)` gives Screen, and returns the previous range so it can
  be set and restored around a block. The shader always works in 0-1; the range
  only says what the numbers you pass mean.
- **`Rect`, `WindowSize` and `GetFlipInterval`**, the Screen queries ported code
  calls without thinking. `GetFlipInterval` differs in one way worth knowing: it
  is measured rather than calibrated at open, returning the least-squares fit to
  the refresh grid once thirty presentations are confirmed, so it improves
  during a run instead of being fixed at startup.
- **A nearest-neighbour sampler**, so `filterMode` 0 means what it does in
  Screen. It matters for noise and checkerboard textures drawn at 1:1, where
  bilinear filtering blurs by a fraction of a pixel wherever the destination is
  not integral.

### Changed

- **A full audit for OpenGL, `Screen` and dead code.** Four things survived the
  earlier removals, all of them invisible at runtime:

  `#import <QuartzCore/CAMetalDisplayLink.h>`, a header for a class the file no
  longer uses. `Record.submitted`, written on every commit and read nowhere;
  `inFlight` beside it carries the same fact and is read. `pendingRequestedTime`,
  assigned in four places and read in none — it belonged to the display-link
  path. `S.prefetch` in the wrapper, set by `OpenWindow` and `PrefetchDrawable`
  and never consulted. Write-only state is worse than no state: it looks like a
  fact the code is keeping track of.

  Two comments described the removed IOSurface blit as though it still ran
  ("encoded into the same render pass as the IOSurface blit... so they composite
  over whatever Screen drew"). It is the drawable's own pass now, cleared by the
  load action. Comments that go stale this way are worse than none, because they
  describe a mechanism convincingly.

  What the audit found NOT to be a problem, having checked: no GL symbol,
  header, framework or `IOSurface` call anywhere in the build; every one of the
  27 mex commands is reached by the wrapper and every wrapper call resolves to a
  mex command; the 51 diagnostic summary fields are declared and set one for
  one; no static function is defined and never called; and the remaining
  mentions of `Screen` in code are all of the form "as `Screen('DrawTexture')`
  does", which is the drop-in contract being documented rather than a call.
- **No file named `PsychMetal*` calls Psychtoolbox any more.** `PsychMetal.m`
  had been clean for a while, but `PsychMetalDotDemo` still called `KbCheck`
  inside its animation loop, which is why the licence banner appeared *after*
  PsychMetal's own open messages rather than before them: the trigger was the
  frame loop, not the window. `KbCheck` is PsychHID, and PsychHID is not
  reimplemented, so the demo briefly exited on a mouse button only; with
  `PsychMetal('KbCheck')` added below, the original's keyboard exit is back and
  the porting note is gone again. `RectCenter` and
  `CenterRectOnPoint` were also removed, from `PsychMetalDotDemo`,
  `PsychMetalRateCompare` and `PsychMetalWhenTest`; each was two lines of
  arithmetic pulling in a whole toolbox.
- **`PsychMetalGeometryCompare` is now `PTBGeometryCompare`.** It opens a
  Psychtoolbox window deliberately — that is the comparison — so the
  `PsychMetal` prefix was a lie about what it loads. The naming rule is now
  exact: `PsychMetal*` runs with Psychtoolbox off the path, `PTB*` requires it.
- **`DrawTexture`'s arguments are Screen's positions**: `filterMode` at 6,
  `globalAlpha` at 7, `modulateColor` at 8. The tint used to sit at 6, so
  `PsychMetal('DrawTexture', w, t, [], dst, 0, 0)` — an ordinary request for
  nearest-neighbour filtering — was read as a black tint and drew nothing. A
  drop-in that silently draws the wrong thing is worse than one that does not
  exist.
- **`DrawDots` takes `dot_type` at position 6**, where 0 is square. Screen's
  1, 2 and 3 all give round dots here; they differ in Screen only by which
  OpenGL smoothing path is taken, and the round dots already compute coverage
  analytically.

### Fixed

- **Presentation timestamps were corrected by a measurement of their own call
  cost.** `OpenWindow` measured `CACurrentMediaTime − GetSecs` and every
  timestamp `Flip` returned was adjusted by it. But both are
  `mach_absolute_time` divided by the same timebase, so the true offset is zero
  and what was being measured is where the clock read lands inside the `GetSecs`
  bracket. Bracketing the read at two different call costs settles it:

  | | residual | round trip | ratio |
  | --- | --- | --- | --- |
  | through the wrapper | 7.083 µs | 59.500 µs | 0.119 |
  | straight to the mex | 0.563 µs | 3.792 µs | 0.148 |

  The residual scales with the call cost rather than staying put, and
  extrapolates to **0.12 µs** at zero cost — inside the 41.7 ns timebase tick.
  One clock. No conversion is applied anywhere now, removing a systematic
  half-microsecond bias and about twenty conversion sites.

  The check is gone from `OpenWindow` too. Verifying it meant calling
  Psychtoolbox's `GetSecs`, which loaded a Psychtoolbox mex and printed its
  licence banner on every window open — to confirm a relationship between two
  system clocks that was measured once and cannot change. It is measured here,
  recorded, and not re-run.

- **`PsychMetal('GetSecs')`**, returning `CACurrentMediaTime` — the clock
  `MTLDrawable.presentedTime` is in, by name rather than by coincidence. Since
  the two clocks are the same, ordinary code can use either.
- **`HideCursor` and `ShowCursor`**, via `CGDisplayHideCursor`. Psychtoolbox's
  are `Screen('HideCursorHelper')`, so calling them loaded the Screen mex and
  printed its banner for one Core Graphics call.
- **`WaitSecs`**, both `WaitSecs(s)` and `WaitSecs('UntilTime', t)`, on
  `mach_wait_until` against an absolute deadline in the same counter
  `CACurrentMediaTime` reports, then a spin. The spin margin adapts: a first
  attempt at 500 µs was measured overshooting by 2.0 ms because the kernel's
  timer slack exceeded it, so the margin now grows when the kernel overruns it.
  The relative form is systematically ~250 µs later than the absolute one,
  because it reads the clock inside the wrapper; the inventory test asserts
  both, with different tolerances, so the advice to use `'UntilTime'` in a loop
  is checked rather than merely written down.
- **`Resolution` and `Resolutions`**, matching `Screen('Resolution')` and
  `Screen('Resolutions')` on `CGDisplayCopyAllDisplayModes` and
  `CGDisplaySetDisplayMode`. They also report `pixelWidth` and `pixelHeight`,
  which Screen does not: a mode is 1710 × 1107 points on this panel while
  PsychMetal draws in 3420 × 2214 pixels, and confusing the two is how a
  stimulus ends up half size. Setting a mode requires the window closed,
  because the drawable is sized at open.
- **`GetMouse` now reads `NSEvent` directly** and returns PIXELS on the
  presentation display, the same coordinates every drawing command takes.
  Psychtoolbox's `GetMouse` is `Screen('GetMouseHelper')` and reports points
  with a bottom-left origin, so the wrapper had been converting — and routing
  the one input command PsychMetal owned straight back through Screen.

### Removed

- **The CAMetalDisplayLink presentation path**, the original 0.2.0
  implementation, kept through 0.3.1 for comparison. Direct presentation
  measures 1.75 refreshes against its 2.995, so it was the slower of two paths
  where only one could be the default. With it go `PMDriver` and its thread
  (127 lines), the display-link branch of `enqueue`, the target-lag calibration,
  `RestartDisplayLink`, `PsychMetalModeCompareTest`, and `OpenWindow`'s `mode`
  argument.

  **Six of the nineteen Diagnostic history columns** went too — the tick
  counter, Apple's raw and corrected target timestamps, and the missed and
  slipped tick counts derived from them. All were structurally zero without a
  display link. The history is thirteen columns now, and
  `calibratedTargetLagFrames`, `observedTargetOffsetFrames`,
  `displayLinkRestarts`, `presentMode` and `calibrated` are gone from the
  summary. `observedFrameLatency` is renamed `projectionLeadRefreshes`, which is
  what it measures.

- **`presentsWithTransaction`**, a diagnostic alternative present path, and the
  `Record` fields only it and the display link used. The core is 2,280 lines,
  down from 2,682.

- **OpenGL, entirely.** Through 0.3.1, opening a PsychMetal window opened a
  128×96 Psychtoolbox window first, purely to supply a GL context and an
  offscreen framebuffer so that two IOSurfaces could be wrapped as GL textures
  with `CGLTexImageIOSurface2D` and attached to it. Screen drew into one
  surface, Metal blitted it into the drawable, and the native shapes went on
  top. That was the only reason any of this needed OpenGL.

  Gone: the GL context requirement, both IOSurfaces (43 MB), the CGL texture
  wrapping, the `glFenceSync`/`glClientWaitSync` pair, the two-surface rotation
  and the buffer index that existed only to alternate them, the full-screen
  blit with its pipeline and sampler, and the `UseOpenGL` command. The core
  links Cocoa, Metal, QuartzCore and CoreGraphics and nothing else.

  The window opens with no Psychtoolbox window at all: geometry from
  `CGDisplayBounds` and `CGGetActiveDisplayList`, nominal refresh from
  `CGDisplayModeGetRefreshRate`, after which the fitted grid supersedes it.
  `Open` returns width, height, ifi and point size rather than being told them.

  **`PsychMetal.m` now contains no Psychtoolbox call at all.** The last one was
  `GetSecs`, inside the check that Psychtoolbox's clock and
  `CACurrentMediaTime` agree — so the only thing loading Psychtoolbox was the
  check that Psychtoolbox's clock matched ours, and it printed the licence
  banner on every `OpenWindow` to verify a relationship between two system
  clocks that cannot change between one window and the next. Measured once,
  recorded, and removed.

  Three files still load a Psychtoolbox mex, all deliberately: `PTBTimingTest`,
  `PTBWhenBug` and `PTBGeometryCompare` measure Psychtoolbox for
  comparison. Four others call `RectCenter` or `CenterRectOnPoint`, which are
  plain `.m` helpers with no mex behind them.

- **`PsychMetalDirectDemo` and `PsychMetalPrimitivesDemo`**, which existed to
  draw with `Screen` into a PsychMetal window. The second was the only visual
  check that the Metal primitives match Screen's output, and it has no
  replacement.
- **`PsychMetalLoopCostProbe` and `PsychMetalContentCostProbe`**, both 2×2
  designs with interop as a factor. Their findings are in `docs/05_results.md`
  and were already marked superseded.
- **`summary.glSyncMs` and the Diagnostic history's `glSyncMs` column**, which
  measured the fence.

### Changed

- **Opening a window prints nothing from Psychtoolbox.** No licence banner, no
  renderer block, no synchronisation tests, and no `DESKTOP COMPOSITOR IS
  ACTIVE` warning. That warning was about `Screen('Flip')` on a host window
  that never flipped, and read as a verdict on PsychMetal's timing to anyone
  opening it on a new machine.
- **The window handle is an opaque token**, not a Psychtoolbox offscreen window
  handle, so it can no longer be passed to `Screen`.
- **`OpenWindow`'s screen argument** defaults to the last active display, as
  `max(Screen('Screens'))` did, and is validated by the core against
  `CGGetActiveDisplayList` rather than by Psychtoolbox.
- Tests that drew their stimulus with `Screen` — `LatchTest`, `TearTest`,
  `WhenTest`, `RateCompare`, `WarmupLength`, `ModeCompareTest` — now draw it
  with PsychMetal, on 0 to 1 rather than 0 to 255.

## 0.3.1 — unreleased, folded into 0.4.0

### Added

- **Native Metal drawing primitives, no OpenGL.** `FillRect`, `FrameRect`,
  `FillOval`, `FrameOval`, `DrawDots`, `DrawLines` and `DrawGabor` share one
  instanced-quad pipeline; the fragment shader computes coverage from a shape
  kind, so curved edges antialias analytically rather than by tessellation.
  2016 shapes per frame, 2000 of them dots, hold 60.000/s with zero skips.
- **`DrawGabor`**, a sinusoidal carrier under a Gaussian envelope, both
  evaluated per fragment. `sigma` is a fraction of the half-size; `freq` is in
  cycles per pixel, following `Screen('CreateProceduralGabor')` so frequencies
  port across unchanged; `angle` and `phase` are degrees. At frequency 0 the
  carrier term is identically 1, so it is exactly a Gaussian envelope rather
  than an approximation of one. A drifting grating is a changed phase argument,
  not a re-upload.
- **`DrawNoise` and `NoiseValues`: full-field white noise with no upload.** A
  pixel's value is a counter-based hash of its position and the seed, evaluated
  in the fragment shader, so nothing is generated on the CPU and nothing is
  transferred. `'uniform'` (default) or `'normal'`; `'mono'` (default) or
  `'colour'` for an independent value per channel; a mean and a spread that is
  the half-range for uniform and the SD for normal. The defaults are uniform,
  monochrome, full spread — every pixel independently and uniformly between
  black and white.

  **The seed is normally an output.** Omit it and one is drawn from the caller's
  RNG and returned, so an experiment records four bytes per frame rather than a
  21 MB array and can reconstruct the stimulus exactly. Pass a seed to redraw a
  frame. A second output, `[seed, values]`, returns the matrix too, but only
  when requested: recomputing a frame is the expensive path the command exists
  to avoid, so it cannot happen by forgetting something.

  This is not an optimisation but the only way it fits in a refresh. Measured
  single-threaded over 2880 × 1864: mono uniform 7.6 ms, colour uniform 15.9 ms,
  mono normal by Box–Muller 50.3 ms, plus 21.5 MB of upload per frame
  (1.3 GB/s at 60 Hz). Normal-distributed full-frame noise cannot be produced
  and uploaded at 60 Hz at any plausible CPU speed.

  Being stateless makes it *more* reproducible than a stream RNG, not less.
  `NoiseValues` recomputes any frame's values from the seed alone, in any order,
  so an experiment stores one integer per trial instead of a 21 MB array and can
  still reconstruct the stimulus for reverse correlation. The hash is duplicated
  between the Metal source and C in the mex, which is the one place this design
  can break; both depend on uint32 wraparound, which is also why the CPU side is
  in C rather than the wrapper — MATLAB and Octave saturate uint32 arithmetic
  instead of wrapping, so a `.m` implementation would be silently wrong. Seeds
  are limited to 0–16777215 and larger values are refused, because the seed
  travels to the shader inside a float32 and above 2^24 it would silently become
  a different seed than the one recorded.
- **Background colour, matching `Screen('OpenWindow')`.** Each frame is cleared
  to `OpenWindow`'s second argument before any drawing, and
  `PsychMetal('BackgroundColor', w, color)` changes it at any time. Previously
  the clear was hardcoded to opaque black and undocumented, so a grey-field
  experiment had to draw a full-screen rectangle every frame. The clear is the
  render pass load action rather than a draw, so it costs nothing. Only visible
  with `UseOpenGL` off; with interop on the blit writes every pixel and the
  clear is skipped.
- **`PsychMetalGaborDemo`**, a field of drifting Gabors at independent
  orientations. Phase advances with predicted presentation time rather than
  with the frame counter, so a dropped frame does not slow the drift, and the
  demo reports measured degrees per frame against the expected value as a check
  on that. Separate `DrawGabor` calls batch into one instanced draw, so the
  achieved rate should barely move between 1 patch and 48.
- **`PsychMetalDotDemo`**, a literal port of Psychtoolbox's `DotDemo.m` with
  every Screen/OpenGL drawing call replaced by its PsychMetal equivalent and
  nothing else changed, so the two can be run side by side. It carries the
  original copyright and history; both projects are MIT licensed. Six things
  had no one-for-one translation and are marked in the file: the 0-1 colour
  range, `BlendFunction` (PsychMetal is fixed at exactly the blend the original
  asks for), `DrawingFinished` (an OpenGL hint, dropped), the gpu point-size
  clamp (dots are instanced quads, so there is no hardware limit to obey),
  `PsychDrawSprites2D` (one `DrawTexture` per sprite, which does not batch),
  and the smiley texture (the original draws it with `Screen('DrawText')`;
  PsychMetal has no text drawing, so it is constructed arithmetically).
- **Native Metal textures.** `MakeTexture`, `DrawTexture` and `CloseTexture`
  upload straight to an `MTLTexture` in `RGBA16Float`. Shapes and textures are
  kept in call order, so a texture drawn after a rectangle appears on top.
- **`GetMouse`**, which converts the pointer into the window's own pixel
  coordinates. Plain `GetMouse` reports points, which differ by the backing
  scale factor on a Retina display in a scaled mode.
- **`UseOpenGL`**, declaring whether a window's frames contain Screen drawing.
  Off removes the fence, the IOSurface rotation and the blit. Not a performance
  switch — see below.
- **`PrefetchDrawable`**, acquiring the next frame's drawable at the end of
  `Flip` rather than the start.
- **Scheduled presentation now uses `presentDrawable:atTime:` and nothing
  else.** Committing immediately and letting Apple place the frame measures 0
  to 1% late across cadences of 1 to 12 refreshes. Computing the commit moment
  ourselves from a fitted grid put a four-refresh request a refresh late on 99%
  of frames — the defect was ours, not the pipeline's, which is why no property
  of the pipeline ever explained it. Frames in flight are capped at two so a
  distant target cannot hold the whole drawable pool.
- **Online dropped-frame detection.** `Flip`'s fifth return value reports how
  many refreshes the previous confirmed presentation missed its prediction by.
  Beam position is unavailable on this hardware and Screen returns a constant
  −1 there, so the slot carries something useful.
- `PsychMetalFrameStats`, one implementation of the run summary that every demo
  and test had been computing inline, with differing bugs.
- Probes: `PsychMetalLoopCostProbe`, `PsychMetalContentCostProbe`,
  `PsychMetalInputLatencyProbe`, `PsychMetalCompositorProbe`,
  `PsychMetalScheduleSweep`, `PsychMetalMixedCadenceProbe`,
  `PsychMetalCallerSleepProbe`.
- **`PsychMetalInventoryTest`**, which exercises every command the wrapper
  exposes and gives each one at least one deliberate misuse, on the principle
  that a command which accepts a wrong argument silently is how a bad value
  reaches the GPU unnoticed. The command list is derived from `PsychMetal.m` at
  runtime, so a command added without a test fails the run and is named. It
  found a real defect on its first run — see the NaN timestamp below — which no
  timing test could have caught, because they all warm up first.

### Changed

- **`OpenWindow`'s second argument is now the background colour**, matching
  `Screen('OpenWindow')`. It was `frameLatency`, which is gone entirely — see
  Removed. **This is a breaking change to a positional argument**, made before
  the first public release for exactly that reason.
- **`drawableCount` now defaults to 3**, was 2. The wrapper and the mex had
  disagreed on the default. With two drawables `Flip` blocks in `nextDrawable`
  until the pool frees one — a full presentation away — leaving about 3.2 ms of
  a 16.67 ms refresh for everything else, so the rate is decided by noise.
  Measured across five configurations: two drawables gave 30 to 57
  presentations/s with 16 to 294 skipped intervals and repeat passes of
  identical work disagreeing by 19 Hz; three gave 60.000 and zero skips in
  every one.
- **Drawable prefetch on by default** with three drawables. Input sample to
  photons fell from 2.95 refreshes to 1.96 at 60.000/s with no skips. Prefetch
  with two drawables starves the pool and halves the rate, so `OpenWindow` ties
  the two settings together and warns on the invalid combination.
- **`NextPhase`, `PrepareFlip` and `PresentNow` are now labelled measurement
  instruments** rather than a recommended stimulus path, in the help and in
  `docs/05_results.md` section 10. The former advice to present at phase 0.625
  came from a drained-queue measurement; under a running loop the correction is
  worth about 4 ms rather than 27, and no closed-loop paradigm has been
  measured end to end.

### Fixed

- **Four commands accepted extra arguments silently.** `MakeTexture`,
  `CloseTexture`, `GetMouse` and `Version` ignored anything past their
  documented arguments, so a value in the wrong slot went unnoticed. They now
  refuse, and the inventory test checks each.
- **The run tally was computed every flip and discarded.** `Flip` counted flips
  and slips into wrapper state that nothing ever read. They are now
  `summary.flips`, `slipFlips`, `lastSlipFlip` and `lastSlipRefreshes` — the
  numbers an experiment most wants at the end of a run.
- **`PrefetchDrawable` was missing from the command list** printed by a bare
  `PsychMetal`, the only one of the 26 not shown.
- **The command list described `Flip`'s fifth output as `beampos`.** It has been
  `slipped` since the online slip detection was added; the detailed `Flip` help
  said so and the summary line did not.
- **The `OpenWindow` help said `drawableCount` defaults to 2.** It defaults to 3.
- **`Flip` returned a presentation timestamp one refresh early** on about half
  of frames, so anything logging it as stimulus onset was wrong by 16.7 ms. The
  prediction took the first grid point at or after a time sampled *before*
  `nextDrawable` and before the commit; a committed frame is presented at the
  *second* grid point at or after the *commit*, measured p01 1.710 and p99
  1.843 refreshes. Median error is now 16 nanoseconds.
- **`Flip` returned `NaN` as the presentation timestamp on the first flips
  after `OpenWindow`.** The refresh grid has no anchor until a presentation is
  confirmed, so `gridPointAtOrAfter` returns `NaN`, and the prediction passed it
  straight to the caller. A caller then computing `vbl + (n − 0.5) * ifi` for
  its next request was told its `when` was not finite. It now falls back to the
  provisional estimate until the grid is anchored. Every timing test warms up 90
  to 120 frames before measuring, which is why none of them ever saw this; a
  real experiment's first flip would have.
- **A late presentation dragged its successors with it.** The schedule stayed
  anchored to a stale timestamp, so the following requests landed in the past.
  Scheduled-gap failures across ~508 presentations went from 6 in a run of 4 to
  between 1 and 3 across repeat runs, always isolated.
- **Shape instance buffers advanced through a four-slot ring at every flush**
  rather than once per frame, so a frame containing several textures could wrap
  the ring and overwrite data that an earlier draw in the same command buffer
  still referenced. Metal reads vertex buffers at GPU execution time, not at
  encode time.
- **`Diagnostic` reported `calibratedTargetLagFrames` and
  `observedTargetOffsetFrames` as about 1.4e+07.** Both derive from
  `CAMetalDisplayLink`'s `targetPresentationTimestamp`, which is never
  populated in direct mode. They now report `NaN` there.
- **`make package` produced a broken distribution.** `PsychMetalFrameStats.m`
  was omitted although eight shipping demos and tests require it, and the file
  list referenced a `.gitignore` that did not exist, so `cp` aborted.
- `Flip` called `Screen('DrawingFinished')` unconditionally, a mex round trip
  and a GL flush for a surface nothing wrote, on the critical path. Skipped
  when OpenGL interop is off.

### Notes on results that did not hold up

The scheduled-presentation defect took many hours and produced a long list of
eliminated causes — a cadence threshold, the deferred submission branch, the
commit lead across a 2.5-refresh range, the rhythm, the preceding request, the
prediction, noise, and an arithmetic coincidence with the drawable count. Every
one of those was a hypothesis about the pipeline, and the cause was that the
library was scheduling at all. One intermediate claim ("only a four-refresh
cadence is affected") was written into these notes from a single run and
retracted when a repeat showed a different set.

Several other conclusions in earlier drafts of `docs/05_results.md` were
measured with two drawables, where the loop sits on the deadline and outcomes are decided by
noise rather than by whatever is being varied. Texture pixel format, the shape
instance ring, OpenGL interop and `GetMouse` each appeared to affect the frame
rate and none of them did. Section 8's scaled-versus-native result was
re-measured under the new defaults and held (1.751 against 1.752 refreshes);
the `preferredFrameLatency` and Game Mode results in sections 2 and 3 were not
re-measured and carry the same caveat.

---

## 0.3.1-notch — 2026-08-19

### Fixed

- **A stimulus position bug on displays with a notch.** AppKit's
  `toggleFullScreen:` placed the window at `y = -safeAreaInsets.top`: correct
  size, wrong origin. Every stimulus was displaced downwards by that inset — 57
  points on a 15-inch MacBook Air — and the bottom rows fell off the panel.
  Anything referenced to screen centre or measured in eccentricity was affected
  in every release before this one. No timing result is affected; those are
  intervals and latencies, which do not depend on where the stimulus sits.
- `Open` now fails rather than warns if the presentation window is not at the
  display origin.

### Changed

- **Presentation window now captures the display** and sits at
  `CGShieldingWindowLevel`, which is what Psychtoolbox does for its OpenGL path.
  The stimulus covers the whole panel including the strip beside a notch,
  verified against PTB in the same process. Startup no longer waits on an
  asynchronous Space transition.

### Removed

- **AppKit managed fullscreen.** It measured identically on presentation timing
  (17.0349 against 17.0379 ms in an adjacent pair) and cannot cover a notched
  display: moving the window to the display origin makes AppKit clamp the
  content view to `visibleFrame`, so it offers the correct origin or the full
  height, not both. With it go `transitionFullscreen`, the fullscreen
  notification observer, the main-thread runloop pumping inside `Flip`, and the
  fullscreen-exit path in `Close`.
- **Game Mode support**, which required AppKit fullscreen. It was measured to do
  nothing in direct presentation mode (1.658 against 1.655 refreshes); its
  one-refresh effect on `CAMetalDisplayLink` is recorded in `docs/05_results.md`
  section 3, and it required declaring the host application a game in its
  `Info.plist`, which a MEX file cannot do. Gone with it: the bundled octave-cli
  host and its launcher script, the Accessory demotion path, and the
  `declaredGameModeEligible`, `gcSupportsGameMode`, `lsSupportsGameMode`,
  `hostAppCategory`, `bundledCommandLineHost`, `finishLaunchingCalled` and
  `reopenedAsAccessory` diagnostic fields. Activation-policy promotion stays: a
  command-line host still needs it to show a window at all.
- Stale files: `BUILD_NOTES.md` (a pre-build document stating the sources had
  never been compiled), `build.sh` and `build_all.sh` (one-line wrappers around
  `make`), and a stray `psychmetal_direct.csv`.

### Added

- `Diagnostic` reports the whole geometry chain — `cgDisplayBounds`,
  `screenFrame`, `screenVisibleFrame`, `screenSafeAreaInsets`, `windowFrame`,
  `viewBounds`, `layerFrame`, `backingScaleFactor` — plus `displayCaptured` and
  the display mode's point and pixel widths against the largest mode available,
  so a scaled resolution is visible.
- `PsychMetalDrawableCompare` and `PTBGeometryCompare`;
  `PsychMetalLatchTest` takes a drawable count.
- `PTBTimingTest` and `PTBWhenBug`, which measure stock Psychtoolbox with the
  same methodology for side-by-side comparison.
- The `Diagnostic` struct field count is now derived from the name array rather
  than a hand-maintained literal, which had already drifted once.

### Measured, and none of it moved the one-refresh presentation lead

Drawable count 2 versus 3 (−0.007 ms against 0.042 ms baseline drift), shielded
versus managed windowing (−0.003 ms), native versus scaled display mode (no
change), and full-panel coverage. See `docs/05_results.md` section 8.

## 0.3.0 — 2026-08-18

- Added a direct presentation mode that acquires and presents drawables inline
  with no CAMetalDisplayLink, and made it the default. Submit-to-present latency
  drops from the display link's two-to-three refresh scheduling horizon to about
  one refresh, matching the acquire/present model MoltenVK uses for a FIFO
  swapchain.
- `Flip` returns a measured `presentedTime` in direct mode instead of a
  prediction, and reports which of the two it returned.
- Kept the 0.2.0 CAMetalDisplayLink path, selectable as `'displaylink'`.
- Added a refresh-grid estimator driven by confirmed presentations, used to
  schedule `when` in direct mode and reported as `summary.measuredRefreshHz`.
- Scheduled `when` in direct mode sleeps until roughly two refreshes before the
  target, then submits with `presentDrawable:atTime:`, so a long hold never
  occupies a drawable from the pool.
- Factored the presented and completed handlers so both paths share them.
- Added an optional `presentsWithTransaction` direct-mode path: commit, wait
  until scheduled, then present explicitly inside a Core Animation transaction.
- `waitForConfirm` now defaults to false. Blocking inside Flip for the confirmed
  presentedTime costs the whole submit-to-present lead, which exceeds one
  refresh, so it halves the presentation rate. Flip returns the predicted grid
  boundary instead and confirmations are collected asynchronously.
- Demos and tests take an optional presentation mode and report the achieved
  presentation rate first.
- Fixed the refresh-grid estimator leaving `measuredRefreshHz` unset whenever
  presentations were spaced more than one refresh apart.
- Detect the bundle having been unloaded and reloaded in one process and fail
  with a clear message instead of segfaulting on the next Open.
- Added `PsychMetal('WaitToDraw', w, targetVbl [, drawBudget])`, which sleeps
  until the latest moment drawing can start and still reach a given refresh
  boundary, so input can be sampled as late as possible. Uses a running
  submit-to-present estimate reported as `summary.leadEstimateMs`.
- Added `PsychMetalMouseDemo`, which measures input-to-photons latency for a
  mouse-tracking stimulus with and without just-in-time sampling.
- The submit-to-present estimate behind WaitToDraw is now a 90th percentile
  rather than a median; undershooting it makes frames miss their boundary.
- Demos and tests report the achieved rate from the mean interval, not the
  median, which masked dropped frames entirely.
- Added `SetDisplaySync`, `GridAnchor` and `NextRefresh`. Turning display sync
  off freezes the refresh grid at its last measured value, so a caller can time
  swaps against the grid itself rather than against Apple's vsync, which
  imposes a one-refresh latch deadline.
- Added `PsychMetalTearTest`: software vsync with a lead-offset sweep and a
  full-field tear stimulus.
- Added `NextPhase`, `PrepareFlip` and `PresentNow`. Which refresh boundary a
  frame reaches depends on the phase within the refresh at which the present
  call is issued, so phase is the real latency control.
- Added `PsychMetalLatchTest`, which locates that deadline by sweeping the
  present-call phase against confirmed presentations.
- `PsychMetalMouseDemo` takes a target phase and uses the two-phase path.
- Added `PsychMetal('Latency?')` summarising the measured timing and the
  open-loop versus closed-loop recommendation, plus help topics for every new
  command.
- Added `RELEASE-0.3.0.txt` and `docs/05_results.md`.
- Added `PsychMetalModeCompareTest`.

## 0.2.0 — 2026-08-16

- Added blocking `PsychMetal('Flip', w, when)` scheduling in the `GetSecs` timebase.
- Schedule directly against each callback's Apple target timestamp instead of extrapolating future ticks.
- Added a measured GetSecs/Core Animation timebase conversion.
- Added rolling sub-refresh correction from confirmed `presentedTime` feedback.
- Added requested-time, signed submission-slack, cadence, and calibration diagnostics.
- Added Apple render-deadline, command-buffer GPU timing, requested/property-readback/observed
  frame-latency, drawable-count, host Game Mode eligibility, and timebase-drift diagnostics.
- Added `PsychMetalWhenTest` for 1–4 refresh spacing, past deadlines, long holds, and far-future waits.
- Added configurable frame latency/drawable count and `PsychMetalLatencySweepTest` for a controlled
  1-vs-2 latency and 2-vs-3 drawable comparison.
- Distinguished the measured target lead (pipeline scheduling horizon) from the much smaller
  confirmed-presentedTime versus raw-target offset.
- Added reversible foreground-application activation-policy promotion and before/after reporting.
- Prepare and activate the host before any PTB/Metal window, then allow AppKit and Game Mode
  to settle after fullscreen entry before starting the display link.
- Renamed the plist-derived Game Mode field to `declaredGameModeEligible`; an actual macOS
  Game Mode notification is stronger evidence than static host-bundle declarations.
- On teardown, demote and hide `octave-cli` launched from an APPL bundle before closing its
  native window; do not retain a phantom keeper window or alter MATLAB/unbundled Octave.
- Explicitly call AppKit `finishLaunching` for that hand-made bundle so its Dock icon does not
  remain indefinitely in the bouncing/launching state and get terminated by the system.
- Exit fullscreen while still Regular, immediately order the stimulus window out, then demote
  bundled octave-cli before closing the invisible window; this avoids both process termination
  and a stale stimulus frame remaining behind Terminal.
- Do not promote an already-running bundled octave-cli from Accessory back to Regular; a fresh
  launcher process is required for each Game Mode session to avoid AppKit re-entry crashes.
- Close the known PTB drawing and host handles directly instead of consulting `Screen('Windows')`,
  which can omit a hidden host and leave its small black window behind.
- Fit refresh rate to the longest uninterrupted confirmed frame sequence, excluding Game Mode
  or display-link startup transitions from the regression.
- Added confirmed-timestamp refresh-rate regression, fit residuals, native mach timebase,
  process name, and macOS-version diagnostics.
- Recover once if a fullscreen or Game Mode transition stops the display-link callback stream;
  preserve and retry the pending frame and report the event as `displayLinkRestarts`.
- Service the AppKit event loop while a main-thread `Flip` waits for display-link acceptance;
  this prevents the bundled Octave CLI and a Game Mode transition from waiting on each other.
- Mark the direct `octave-cli` application wrapper unsupported after repeated callback-stream
  suspension, and add a LaunchServices-based GUI Octave Game Mode launcher.
- Explicitly request persistent GUI mode from LaunchServices and capture both Octave output
  streams for launcher diagnosis.
- Launch Homebrew's real `octave-gui` executable directly so the running process retains the
  wrapper's bundle identifier and Game Mode declarations.
- Remove XQuartz/`DISPLAY`, safe-area, and plist environment changes from the timing launcher;
  provide separate identity-only and Game Mode app configurations for controlled comparison.
- Remove `KbCheck` from the fixed-length direct demo so Input Monitoring permission is not a
  prerequisite for testing Metal presentation and Game Mode.

## 0.1.1 — 2026-08-16

- Fixed buffer reuse after Metal fails to provide a drawable.
- Made failed opens and shutdown drain native resources safely.
- Moved the display link to a dedicated user-interactive thread.
- Replaced the global OpenGL stall with a per-frame GPU fence.
- Added strict MEX argument, IOSurface, Metal texture, and framebuffer checks.
- Added confirmed-timestamp reporting to the demo and removed its Statistics Toolbox dependency.
- Added OpenGL synchronization and missed-refresh fields to `Diagnostic`.
- Added `PsychMetal('Version')` and explicit macOS 14 / Apple-silicon checks.
- Closed the final-frame diagnostic race and made OpenGL fence timing unquantized.

## 0.1.0 — 2026-08-15

- Initial experimental release.
