# HDR / EDR — 0.10.1

Opt-in relative-linear HDR on Apple displays with EDR headroom. SDR behavior is
unchanged. This is not calibrated absolute-nits output, HDR10/PQ/HLG movie
playback, or a claim about physical onset/brightness accuracy.

```python
with pm.open_window(hdr=True, readback=True) as (w, rect, ifi):
    pm.color_range(w, 1)
    tex = pm.make_texture(w, np.full((128,128), 4, dtype=np.float32))
    pm.draw_texture(w, tex)
    pm.flip(w)
    image = pm.get_image(w)  # float32 RGB; can exceed 1
    print(pm.hdr_info(w))
```

```matlab
[w,rect,ifi] = PsychMetal('OpenWindow',struct('hdr',true,'readback',true));
PsychMetal('ColorRange',w,1);
t = PsychMetal('MakeTexture',w,single(ones(128)*4));
PsychMetal('DrawTexture',w,t); PsychMetal('Flip',w);
image = PsychMetal('GetImage',w); % single RGB, relative-linear values
info = PsychMetal('HDRInfo',w);
PsychMetal('Close',w);
```

The layer uses RGBA16Float, extended-linear Display-P3 and EDR enabled, following
Apple's Metal-layer EDR configuration. 1 is SDR reference white; values above 1
use available headroom. HDR disables display capture by default because this
path relies on compositor-managed colour. Explicit capture=true is refused.
HDR requires iOS 16+ or a supported Mac display; a screen reporting no potential
headroom causes an error, rather than silently substituting SDR. Headroom can
change with brightness, power and display settings. Query HDRInfo outside timed
loops; opening EDR can take time to raise current headroom.

Floating texture uploads preserve finite nonnegative RGB through 65504; alpha
remains 0..1. Byte images retain their numeric 0..255 mapping, not automatic sRGB
transfer conversion. Basic colour arguments still use normalized SDR-white
values; use HDR textures, custom shaders or an exposure pipeline for extended
RGB. Custom shaders and procedural drawing preserve extended output in HDR;
recipe mean/contrast parameters retain their documented ranges. Masks remain
coverage, clamped to 0..1. HDRExposure / hdr_exposure(w, stops) multiplies the
finished linear scene by 2**stops (-16..16); it does not change display brightness
or establish nits. No automatic tone mapping is inserted. Values beyond current
headroom can clip in the compositor/display. SDR gamma/LUT Linearize is refused
in HDR; colour matrices/exposure belong in the linear imaging pipeline.

GetImage/readback returns RGB float32 from the HDR drawable, preserving extended
values; reusable Python out arrays must have float32 dtype. This captures GPU
pixels before compositor/display processing, not emitted light. Current movie
recording/decoding is SDR-only and is explicitly refused in HDR windows.
Standalone movie export remains SDR. Physical HDR acceptance is pending.

Demos: python/hdr_demo.py and PsychMetalHDRDemo; HDR brightness in the phone app.
A 7x7 grid compares every pair of 0.5, 1, 2, 4, 8, 12 and 16x SDR white.
Each cell alternates its row level and column level; diagonal cells keep the
same level throughout. Smaller steady circular references appear below.
All stimuli are circular, with precomputed antialiased alpha masks.

Startup measures the confirmed refresh grid. Each level is held for an equal
integer number of submitted frames. The target defaults to 16 Hz; the nearest
attainable frame-grid rate is selected (ties choose the lower rate). At 60 Hz,
two frames per level gives 15 Hz; at 120 Hz, four per level also gives 15 Hz.
A 96 Hz display can produce exactly 16 Hz with three frames per level.

MATLAB/Octave: PsychMetalHDRDemo(seconds, targetHz), e.g.
PsychMetalHDRDemo(60,16). Python: hdr_demo(seconds=60,flicker_hz=16), or run
python/hdr_demo.py 60 16. Target arguments accept 1..60 Hz; a slower display
limits the available rate. The phone uses on-screen rate controls while the demonstration is running.
During the demo, tap/click Slower/Faster or use Left/Right arrow keys to step
through whole-frame hold counts. Adjustments apply at full-cycle boundaries,
preserving equal dwell for both levels. Slower is bounded near 1 Hz; Faster
ends at one frame per level. requestedHz records the initial target; rateHistory
records elapsed seconds, half-cycle frame count and frame-grid frequency.

The screen reports the rate on the measured frame grid; dropped refreshes can
lengthen a hold. Transposed cells run in opposite phase so the global luminance
histogram stays constant. One batch submits all 49 comparisons and seven
steady references.

Current/potential headroom is refreshed at 2 Hz. Stars on the steady-reference
labels mark requests above current headroom, which may clip. These educational
displays are not timing benchmarks or a guarantee of perceptual equality when
no flicker is visible. The returned hdr is the final query; headroomHistory
records elapsed seconds, current and potential headroom. ifi, halfCycleFrames
and flickerHz report the calibrated grid and selected cadence.

Apple: [EDR tone mapping/configuration](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping),
[EDR layer flag](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent).
