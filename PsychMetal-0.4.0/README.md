# PsychMetal 0.4.0 — a direct Metal replacement for Screen, on Apple silicon

PsychMetal presents stimuli through a direct macOS Metal path, with native
Metal drawing primitives. **There is no OpenGL anywhere in it** as of 0.4.0: no
GL context, no IOSurface, no `Screen` window. It does not use `Screen('Flip')`,
and does not go through Vulkan or MoltenVK.

**PsychMetal itself calls no Psychtoolbox function.** Opening a window,
drawing, flipping, reading the mouse, hiding the cursor, waiting, reading the
clock and changing the display mode are all Core Graphics, AppKit and Metal
directly. Nothing prints a licence banner, sync tests, or the
desktop-compositor warning that used to describe a host window that never
flipped.

**The file name says whether Psychtoolbox is involved.** Every file named
`PsychMetal*` runs with Psychtoolbox absent from the path — no `Screen`, no
`KbCheck`, nothing that loads a Psychtoolbox mex, so nothing prints the licence
banner. The three files named `PTB*` (`PTBTimingTest`, `PTBWhenBug`,
`PTBGeometryCompare`) require Psychtoolbox on purpose: they exist to measure it
so PsychMetal has something to be compared against.

`PsychMetal('KbCheck')` reads the keyboard without PsychHID, because macOS has
already merged every attached keyboard — built-in, USB, Bluetooth — into one
system-wide state, and reading that state needs no device enumeration. It
returns Psychtoolbox's `keyCode` indices, so `keyCode(41)` is Escape here as it
is there. **It is not a reaction-time instrument**: the timestamp is when you
polled, not when the key went down, so its resolution is your polling interval
and a Bluetooth keyboard adds tens of milliseconds of its own on top. It cannot
say which keyboard a press came from, and it cannot see a response box that
does not present itself as a keyboard. That is what PsychHID is for, and
PsychHID is not reimplemented here.

MIT licensed. Psychtoolbox is not required to run PsychMetal and is not
bundled; only the three `PTB*` comparison files need it.
`PsychMetalDotDemo.m` is derived from Psychtoolbox's `DotDemo.m` and carries its
original copyright and history; both projects are MIT licensed. No other file
here contains Psychtoolbox source.

**Experimental research software, not a validated replacement for Psychtoolbox
timing.** Every number here is a software timestamp derived from
`MTLDrawable.presentedTime`. None of it has been checked against a photodiode.
Do that before trusting it in an experiment.

Requires Apple silicon. Built with a deployment target of macOS 14, though the
newest API it actually uses is `addPresentedHandler` (10.15.4), so the real
floor is probably lower and nobody has checked. **Measured only on macOS 27.0
beta**, on a MacBook Air (M4, 15-inch), with Octave 11.3. A beta OS is a real
caveat for timing figures: read every number here as "on this build".

---

## Quick start

```matlab
[w, rect, ifi] = PsychMetal('OpenWindow', [], 128);   % mid-grey background

for k = 1:600
    PsychMetal('FillOval', w, [255 0 0], [100 100 300 300]);
    vbl = PsychMetal('Flip', w);
end

PsychMetal('Close', w);
```

`PsychMetal` with no arguments lists every command. Append a question mark for
detail: `PsychMetal('Flip?')`, `PsychMetal('Latency?')`.

### Drop-in for Screen

The argument formats are `Screen`'s, deliberately, so that replacing `Screen(`
with `PsychMetal(` in existing code is meant to work:

```matlab
PsychMetal('FillOval', w, [255 0 0], rect);
PsychMetal('DrawTexture', w, tex, [], dst, angle, filterMode, globalAlpha);
PsychMetal('DrawDots', w, xy, size, colors, center, dot_type);
ifi = PsychMetal('GetFlipInterval', w);
[vbl, onset, t, missed] = PsychMetal('Flip', w, when);
old = PsychMetal('Resolution', screen, width, height);
PsychMetal('HideCursor');
t = PsychMetal('WaitSecs', 'UntilTime', when);
[down, secs, keyCode] = PsychMetal('KbCheck');
```

**Colours open on 0 to 255**, exactly as `Screen`'s `ColorRange` does, and
`PsychMetal('ColorRange', w, 1)` switches to the 0-1 convention that
`PsychDefaultSetup(2)` gives Screen. This matters more than it looks: at 0-1 a
ported script would render every stimulus at 1/255 of its intended brightness,
silently, because 255 and 128 both clamp to white.

What is *not* copied is how Screen does things internally. Nothing here mimics
an OpenGL implementation detail, and where Metal offers a better answer it is
taken — `DrawGabor` and `DrawNoise` have no Screen equivalent, `GetFlipInterval`
returns a value measured during the run rather than calibrated at startup, and
`DrawDots` has no hardware size limit to clamp against.

`OpenWindow`'s second argument is the background colour, as in
`Screen('OpenWindow')`: each frame is cleared to it before any drawing, and
`PsychMetal('BackgroundColor', w, color)` changes it later. It is the render
pass load action rather than a draw, so it costs nothing per frame — cheaper
than a full-screen `FillRect`. Default black.

---

## What it measures

| | |
| --- | --- |
| Presentation rate | 60.000/s, zero skipped intervals |
| Interval stability | 84 ns spread across 300 frames (2 timebase ticks) |
| Input sample → photons | 1.96 refreshes |
| Commit → photons | 1.75 refreshes (N+2) |
| Predicted vs confirmed onset | exact to ~16 ns in a continuous loop |
| Refresh period | 59.999894 Hz, repeatable to 0.043 ppm |

Full measurements, including what was tried and did not work, are in
`docs/05_results.md`.

---

## Two settings that matter

**`drawableCount`, default 3.** Two drawables cannot sustain 60 Hz from a
Metal-only loop: `Flip` blocks in `nextDrawable` until the pool frees one, which
is a full presentation away, leaving about 3.2 ms of a 16.67 ms refresh for
everything else. Measured across five configurations, two drawables gave 30 to
57 presentations/s; three gave 60.000 with zero skips in every one.

**Drawable prefetch, on by default with three drawables.** The next frame's
drawable is acquired at the *end* of `Flip` rather than the start, so the
unavoidable wait falls before the caller's next input sample instead of after
it. Worth a full refresh of input latency at no cost in rate: sample-to-photons
went from 2.95 refreshes to 1.96.

These are tied together in `OpenWindow`. Prefetch with two drawables starves the
pool — it holds one of two, leaving nothing to pipeline against, and the rate
halves — so asking for that combination warns.

---

## Native Metal drawing

`FillRect`, `FrameRect`, `FillOval`, `FrameOval`, `DrawDots`, `DrawLines`,
`DrawGabor` and `DrawNoise` are implemented directly in Metal with no OpenGL.
All eight share one instanced-quad pipeline; the fragment shader computes
coverage from a shape kind, which is why the curved ones antialias analytically
without tessellation.

```matlab
PsychMetal('DrawGabor', w, 255, rect, sigma, freq, angle, phase);
```

Colours are on the window's `ColorRange`; `sigma` is a fraction of the
half-size; `freq` is in cycles per pixel, matching
`Screen('CreateProceduralGabor')`; `angle` and `phase` are degrees. **At
frequency 0 it is exactly a Gaussian** — the carrier term is identically 1, not
an approximation of one. Both the envelope and the carrier are evaluated per
fragment, so there is no texture to upload and a drifting grating is a phase
argument rather than a new upload.

### White noise without an upload

```matlab
seed = PsychMetal('DrawNoise', w, rect);              % uniform, mono, black to white
PsychMetal('DrawNoise', w, rect, seed);               % redraw that exact frame
values = PsychMetal('NoiseValues', w, rect, seed);    % rebuild it, no drawing
```

A pixel's value is a hash of its position and the seed, evaluated in the
fragment shader. Nothing is generated on the CPU and nothing is uploaded.

**The seed is normally an output.** Leave it out and one is drawn from your RNG
and returned; record that integer and the frame is reconstructible from four
bytes. `[seed, values] = PsychMetal('DrawNoise', ...)` returns the matrix as
well, but only when asked — recomputing a frame is the expensive path this
command exists to avoid, so it can't happen by accident.

Defaults are uniform, monochrome, full spread: every pixel independently and
uniformly between black and white. `'normal'`, `'colour'`, a mean and a spread
are each one argument away, and the mean and spread are both on the window's
`ColorRange` — at 255, `mean 128, spread 128` is black to white. `NoiseValues`
reports in the same units, because those are the values that were shown.

That is not an optimisation — it is what makes full-field noise possible at all.
Measured single-threaded over 2880 × 1864:

| | CPU generation |
| --- | --- |
| mono uniform | 7.6 ms |
| colour uniform | 15.9 ms |
| mono normal (Box–Muller) | 50.3 ms |

plus 21.5 MB of upload per frame, 1.3 GB/s at 60 Hz. Normal-distributed
full-frame noise does not fit in a refresh from the CPU at any plausible speed.

Being stateless also makes it *more* reproducible than a stream RNG, not less:
any frame's values are recomputable from the seed alone, in any order, so a
session stores one integer per trial instead of a 21 MB array and can still
reconstruct the stimulus for reverse correlation.

`MakeTexture`, `DrawTexture` and `CloseTexture` upload straight to an
`MTLTexture` in `RGBA16Float`.

Shapes and textures are kept in **call order**, so a texture drawn after a
rectangle appears on top of it. Argument order follows the matching `Screen`
commands. 2016 shapes per frame, including 2000 dots, hold 60.000/s with zero
skips.

## Scheduling

```matlab
vbl = PsychMetal('Flip', w, when);   % present at or after `when`
```

Scheduled presentation is handled entirely by `presentDrawable:atTime:` — the
frame is committed immediately and Apple places it. Earlier versions computed
the commit moment from a fitted refresh grid instead and put a four-refresh
request a refresh late on 99% of frames. Three consecutive sweeps of cadences 1 to
12 are 0 to 1% late. The same change took the returned timestamp from 23.6% of
frames a refresh early to 0.2%. `docs/05_results.md` 9e.

`Flip` returns `[VBLTimestamp, StimulusOnsetTime, FlipTimestamp, Missed,
Slipped]`. The fifth output is PsychMetal's, not Screen's: beam position is
unavailable on this hardware and Screen returns a constant −1 there, so the slot
carries how many refreshes the **previous** confirmed presentation missed its
prediction by. Zero means it landed where predicted. That makes a dropped frame
detectable while the experiment is running.

```matlab
[vbl, ~, ~, missed, slipped] = PsychMetal('Flip', w);
if slipped, warning('dropped %d refreshes', slipped); end
```

---

## Known issues

- **The first flip after an idle period is probably predicted a refresh late.**
  The prediction assumes a committed frame appears two boundaries later, which
  holds for a continuous loop. With the queue drained it appears to be one
  boundary. Untested and uncharacterised — two observations on different code
  paths — but it applies to the start of a trial, which is where it matters.
- **Sporadic late presentations**, 0.2 to 0.8% across runs, occasionally in runs
  of two or three. Pre-existing and not understood.
- **One refresh of compositor latency** that no application-visible setting
  removes. See `docs/05_results.md` section 9d — the frame is complete and idle
  for a full refresh before it is shown, and with vsync off the same frames
  reach the display in a quarter of a refresh.
- **`DrawNoise` and `NoiseValues` are not cross-verified on device.** Both
  implement the same hash, one in Metal and one in C, and nothing compares what
  was drawn against what `NoiseValues` returns. Reading the drawable back would
  settle it. The CPU side alone measures uniform sd 0.5775 (1/√3, correct),
  normal sd 1.00000, channel correlation −0.002 and neighbouring-pixel
  correlation +0.001.
- **No photodiode validation.** The largest open question, and the reason none
  of this should be trusted for a real experiment yet.

---

## Installing

The folder is self-contained. Unzip it, then add it to the path:

```matlab
cd /path/to/PsychMetal
addpath(pwd);
savepath;          % optional, to keep it for future sessions
```

MATLAB loads `PsychMetalCore.mexmaca64`, Octave loads `PsychMetalCore.mex`, and
both are included, so there is nothing to compile.

### If macOS refuses to load the mex

The binaries carry the ad-hoc signature Apple's linker produces. They are **not**
signed with a Developer ID and not notarized, so a browser download arrives with
the quarantine attribute set and Gatekeeper may stop MATLAB or Octave from
loading them. The symptom is a load failure, not a PsychMetal error message.

The safest fix is to read the source and rebuild locally — see below; it takes a
few seconds and needs no MATLAB licence for the Octave build. If you would
rather use the supplied binaries, clear quarantine on that folder only:

```
cd /path/to/PsychMetal
xattr -dr com.apple.quarantine .
```

Do not disable Gatekeeper globally to solve this. Re-signing should not be
needed, since both binaries are already linker-signed; you can check with
`codesign --verify --verbose=2 PsychMetalCore.mex`.

---

## Building

```
make octave     # PsychMetalCore.mex
make matlab     # PsychMetalCore.mexmaca64, needs MATLAB_ROOT
make package    # path-ready folder in dist/PsychMetal
```

Prebuilt binaries for both are checked in, so the package works without a
compiler. If MATLAB is installed somewhere other than the Makefile's default:

```
make matlab MATLAB_ROOT=/Applications/MATLAB_R2026a.app
```

---

## Tests and demos

| | |
| --- | --- |
| `PsychMetalInventoryTest` | every command, and a deliberate misuse of each |
| `PsychMetalMinimalDemo` | smallest working loop |
| `PsychMetalBlobDemo` | counterphasing Gaussian, evaluated in the shader |
| `PsychMetalGaborDemo` | drifting Gabors, computed per fragment, never uploaded |
| `PsychMetalNoiseDemo` | full-screen dynamic noise, and a frame rebuilt from its seed |
| `PsychMetalDotDemo` | PTB's `DotDemo`, ported to Metal for side-by-side comparison |
| `PsychMetalTextureDemo` | one upload, many draws |
| `PsychMetalMouseRectDemo` | input latency, end to end |
| `PsychMetalKbDemo` | an on-screen keyboard that lights up as you type, and the test for the two keycode tables |
| `PsychMetalWhenTest` | scheduled presentation, 543 flips |
| `PsychMetalLatchTest` | which refresh boundary a present reaches |
| `PsychMetalInputLatencyProbe` | where the drawable wait sits in the frame |
| `PsychMetalCompositorProbe` | is the WindowServer still in the path |
| `PTBTimingTest` | the same measurements on unmodified Psychtoolbox |
| `PTBWhenBug` | the scheduled-presentation case, on Psychtoolbox |
| `PTBGeometryCompare` | does the stimulus cover the whole panel, both paths |

Every probe prints what its own result would have to look like to falsify the
claim it is testing.
