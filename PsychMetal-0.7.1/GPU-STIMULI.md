# GPU stimulus system — 0.7.0

Added in 0.7.0. The native modules build for Octave, MATLAB and Python; live rendering and timing require hardware acceptance before use in experiments.

## What is new

MakeStimulus / make_stimulus creates a reusable description of a sinusoidal grating or seeded noise field. DrawStimulus / draw_stimulus sends a small parameter block to a Metal shader. No carrier image is generated on the CPU or uploaded each frame. The recipe is a MATLAB struct or an immutable Python tuple and can be reused across sessions. No CloseStimulus call is needed.

An optional one-channel texture supplies mask coverage: 0 is transparent and 1 opaque. It is uploaded with MakeTexture once and sampled independently of the procedural pattern. Drawing the mask into a larger destination enlarges the aperture without enlarging noise cells or changing grating cycles per pixel. Close it with CloseTexture when no longer needed; queued draws retain their mask version until GPU completion. If a source image uses black to mean inside, convert it to coverage first, as in the demo.

The same draw can additionally apply a rectangular, elliptical or Gaussian aperture. Image coverage, procedural aperture coverage and opacity multiply. Built-in apertures do not need a mask texture. Native pipelines are prepared with the corresponding window/target pipelines; the draw itself does not compile a shader.

Drawing respects the current blend mode, clip, offscreen target and linearization path. Each draw captures its own parameters and mask version, allowing different phases/positions in one frame and safe subsequent texture updates. Existing commands keep their 0.6.0 interfaces.

## MATLAB / Octave

Start a fresh host before switching native builds.

```matlab
addpath(fullfile(getenv('HOME'),'Developer','PsychMetal','PsychMetal-0.7.0'),'-begin');
PsychMetalStimulusDemo(20)
```

For the original mask demonstration:

```matlab
PsychMetalStimulusDemo(30, fullfile(getenv('HOME'),'Desktop','PsychMetal','mask.tif'))
```

Space switches the movable patch between colored noise and a drifting grating. Click or Escape exits. The background is a centered, full-height noise square on black; the patch begins centered and has half the display height. Both carriers retain their scale as the mask is resized.

Minimal API example (w is an open window):

```matlab
s = PsychMetal('MakeStimulus','grating',struct('mean',.5,'contrast',.8,'frequency',.025));
PsychMetal('DrawStimulus',w,s,[100 100 500 500],[],struct('phase',90,'aperture','ellipse'));
PsychMetal('Flip',w);
```

Signature: `recipe=PsychMetal('MakeStimulus',kind[,options])`; `PsychMetal('DrawStimulus',window,recipe[,destination,maskTexture,overrides])`. Empty destination uses the target window's full rect. Empty mask means no image mask. Options and overrides are scalar structs; an override affects only that draw.

## Python

Using the bundled extension requires matching ARM64 Python 3.14. Otherwise build with your Python using `make python PYTHON=/path/to/python`.

```bash
cd ~/Developer/PsychMetal/PsychMetal-0.7.0/python
python3 stimulus_demo.py --seconds 20
```

```python
s = pm.make_stimulus('noise', mean=.5, contrast=.8, colour=True, seed=37)
pm.draw_stimulus(w, s, [100, 100, 500, 500], mask=mask_texture, opacity=.75)
pm.flip(w)
```

Python uses the same option names and values. Omit the destination or pass None for the full target. The recipe tuple is an opaque description: change parameters through draw overrides or make a new recipe, not by editing tuple entries. A mask is an existing one-channel MakeTexture handle, not a host array.

## Parameter conventions

Recipe mean/contrast/opacity are always normalized, independent of ColorRange.

| Option | Default | Meaning |
|---|---|---|
| kind | required | `grating` or `noise` |
| mean | .5 | Scalar or RGB baseline, 0–1 |
| contrast | 1 | Amplitude divided by mean, 0–1 |
| frequency | .02 | Grating cycles per display pixel, 0–.5 |
| orientation | 0 | Frequency-vector angle in degrees, clockwise from right; 0 gives vertical bars |
| phase | 0 | Degrees; 0 gives a cosine crest at the destination center |
| seed | 1 | Integer 0–16777215; same seed, coordinates and options reproduce noise |
| grain | 1 | Noise-cell size in display pixels, 1–16384 |
| colour | false | Independent RGB noise when true; shared deviate otherwise |
| normal | false | Gaussian deviates when true; uniform otherwise |
| opacity | 1 | Overall alpha, 0–1 |
| aperture | rect | `rect`, `ellipse` or `gaussian` |
| sigma | .35 | Gaussian standard deviation in fractions of aperture half-width/half-height |

Grating: `mean * (1 + contrast * cos(2*pi*frequency*projection + phase))`, where phase is converted from degrees and projection uses local coordinates relative to the destination center. Its wavelength remains fixed in pixels when destination size changes. Noise: `mean * (1 + contrast * deviate)`; uniform deviate is approximately -1..1, normal deviate is standard Gaussian. Values are clamped to 0..1, so Gaussian noise and means above .5 can clip. Contrast is not a guarantee of the rendered sample's RMS contrast or exact empirical mean. Black mean produces black output.

Noise coordinates are local to the destination's top-left; its pattern moves with the aperture. Changing the seed changes the pattern. Grain=1 is one noise sample per display pixel for an integer-aligned destination. Use integer rectangle edges to preserve pixel alignment. The image mask uses bilinear filtering; this does not interpolate or enlarge the noise carrier.

Temporal animation is explicit: change phase as a function of the desired time, or change seed once per desired noise update. There is no autonomous clock inside the shader. For a drifting grating, `phase = initialPhase - 360 * temporalFrequency * elapsedSeconds`. Use scheduled presentation times when precise temporal phase is required; the demo uses elapsed host time and makes no phase-timing guarantee.

## Validation

`tests/test_stimulus_native.py` compiles the actual native draw function and shared validator with GPU-free resource stubs under address/undefined-behavior sanitizers. It checks finite/range validation, rejection without appending a draw, mask lifetime, captured phase, blend and clip. Front-end tests exercise both public commands and demo control/cleanup paths against the scripted engine. The scripted engine does not simulate procedural pixels.

`tests/test_stimulus_metal.mm` renders with the real new shader into a GPU texture: it checks grating frequency, phase reversal and orientation, deterministic/reseeded noise, grain size, unchanged noise scale under resizing, an uploaded mask, and ellipse/Gaussian apertures. It exits with code 77 when no GPU is available. Run it on a GPU-accessible Mac:

```bash
clang++ -std=c++17 -fobjc-arc -framework Foundation -framework Metal tests/test_stimulus_metal.mm -o /tmp/PsychMetalStimulusTest
/tmp/PsychMetalStimulusTest
```

Run the full suite (`make test`), the new demo in each host, and existing hardware/readback/timing checks before release. Offscreen/linearized/10-bit combinations should receive additional real-window acceptance; their existing pipeline integration alone is not a hardware verification. No 0.7.0 timing measurements or GPU pixel passes are claimed from the development session.

This first implementation supports noise and sinusoidal gratings plus independent coverage masks. It does not yet provide arbitrary user shaders, masked image/video sources, shader-generated mask handles or a stimulus timeline.
