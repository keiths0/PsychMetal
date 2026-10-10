# Reusable analytic GPU masks — 0.8.0 development

`make_mask` / `MakeMask` creates a reusable coverage recipe for procedural noise
or gratings. Metal evaluates coverage at each display pixel. No full-size mask
image is generated or uploaded, and no mask texture/pipeline is created per draw.
The recipe itself is CPU data; it does not require an open window or a close call.
Gaussian masks use a squared-distance exponential without a square-root operation.

```python
noise = pm.make_stimulus('noise', grain=1, seed=13)
ring = pm.make_mask('annulus', inner=.5, radius=1, edge=.08)
pm.draw_stimulus(w, noise, [100, 100, 500, 500], ring)
pm.flip(w)
```

```matlab
noise = PsychMetal('MakeStimulus','noise',struct('grain',1,'seed',13));
ring = PsychMetal('MakeMask','annulus',struct('inner',.5,'radius',1,'edge',.08));
PsychMetal('DrawStimulus',w,noise,[100 100 500 500],ring);
PsychMetal('Flip',w);
```

The default `stimulus_demo.py` / `PsychMetalStimulusDemo` demonstrates a reusable
raised-cosine mask. Its image-file option in MATLAB/Octave still uses the supplied
image. The 0.8.0 phone app includes the same Python demo after native wheels are
rebuilt. Earlier native binaries cannot interpret the new recipe/uniform layout;
restart the host when switching builds.

## Geometry and options

Coordinates are normalized to the destination's half-width and half-height.
Center `[0, 0]` is its center; `[1, 0]` is its right edge. Radius 1 reaches the
midpoints of the destination edges. A nonsquare destination gives an ellipse.
Mask center, radius and edge do not alter grating cycles/pixel or noise grain
size. Changing grating orientation/phase does not rotate or shift the mask.

| Kind | Options and defaults |
|---|---|
| `ellipse` | `radius=1`, `edge=0`, `center=[0,0]`, `invert=false` |
| `gaussian` | `sigma=.35`, `center=[0,0]`, `invert=false` |
| `annulus` | `inner=.5`, `radius=1`, `edge=.05`, `center=[0,0]`, `invert=false` |
| `raised_cosine` | `radius=1`, `edge=.1`, `center=[0,0]`, `invert=false` |

All numerical values must be finite. Radius must be positive and at most 10;
annulus inner radius must be nonnegative and smaller than its outer radius.
Sigma is .001 to 10. Center components are limited to ±10. Invert is 0 or 1.
Options not applicable to a kind are rejected.

`edge` is an **inward** raised-cosine transition in half-aperture units. For an
outer radius R and edge E, coverage is 1 at or inside R-E, .5 at R-E/2, and 0
at or beyond R. An annulus also rises from 0 at `inner` to 1 at `inner+edge`;
its two transition widths cannot exceed its ring width. For an inner radius of
0 there is no central hole or inner transition. Edge 0 is exactly hard: a pixel
is wholly inside or outside, by where its centre lies, so a mask and its inverse
(or a disc inside an annulus of the same radius) tile without a seam and two
noise images that meet there are never mixed. For a smoothed edge give a small
positive edge instead, about one pixel: 1/(half the destination's width).
`raised_cosine` requires a positive edge. Gaussian coverage is
`exp(-r*r/(2*sigma*sigma))`; it has no extra radial cutoff. All masks, including
inverted masks, are clipped by the destination rectangle.

Coverage supplies alpha, multiplied by the stimulus's optional built-in aperture,
image mask and opacity. Ordinary alpha blending gives a soft boundary; additive
blending uses the same coverage as its source weight. Copy blending into a window
writes straight RGB wherever coverage is positive; it does not fade RGB toward
the background. Copy into an offscreen target stores premultiplied RGB/alpha,
following the existing offscreen contract. Linearization is applied after scene
composition, as for other stimuli.

## Combine with an image mask

```python
image_mask = pm.make_texture(w, coverage_image)  # one channel: 0 transparent, 1 opaque
pm.draw_stimulus(w, noise, destination, image_mask, coverage=ring)
```

```matlab
imageMask = PsychMetal('MakeTexture',w,coverageImage);
PsychMetal('DrawStimulus',w,noise,destination,imageMask,[],ring);
```

Recipes and image masks use the same destination UV coordinates. Recipe values
are snapshotted into the native queued draw; image masks retain the precise
texture version until GPU completion. A captured native timeline retains those
same snapshots. The image texture can be closed after drawing; the recipe needs
no close operation. Updates to the host recipe do not change an already queued
frame. Arbitrary nesting of mask recipes is not exposed in this version.

Native layout is eight doubles: `[kind, sigma, inner, radius, edge, centerX,
centerY, invert]`, kind 0 ellipse, 1 Gaussian, 2 annulus, 3 raised cosine.
The shared `checkMask` validator is used by both language bindings and drawing.
Native `drawStimulus` accepts an optional coverage ArrayView after the image-mask
handle. The existing 15-value stimulus recipe remains unchanged.

## Validation limits

CPU sanitizer tests verify validation, snapshots and image-resource retention.
Real-binding tests cover constructors, malformed inputs and image combination.
`tests/test_stimulus_metal.mm` checks actual shader coverage, Gaussian offset,
annulus/raised-cosine transitions, inversion, image masks/opacity, legacy ellipse
agreement, premultiplied offscreen storage, blend factors, 8/10-bit/half-float
output and gamma encoding. It must run on a machine with an accessible Metal GPU;
compiling the test alone does not confirm those pixels. New iOS wheels, Mac and
phone visual/timing acceptance remain pending.

Analytic masks also apply to still images through DrawMaskedTexture /
draw_masked_texture. See MASKED-IMAGES.md for crop, rotation and alpha semantics.
