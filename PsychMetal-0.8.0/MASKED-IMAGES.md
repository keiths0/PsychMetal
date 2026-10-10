# Masked still images — 0.8.0 development

`DrawMaskedTexture` / `draw_masked_texture` samples an existing image texture
through reusable GPU coverage. It uses the shared native engine on macOS and iOS;
there is no CPU mask resizing or per-frame image upload. Video and audio are
outside the 0.8.0 scope.

```python
texture = pm.make_texture(w, image)  # NumPy grayscale, RGB or RGBA image
mask = pm.make_mask('raised_cosine', edge=.15)
pm.draw_masked_texture(w, texture, mask, dst_rect=[100,100,500,500])
pm.flip(w)
```

```matlab
texture = PsychMetal('MakeTexture', w, imread('image.png'));
mask = PsychMetal('MakeMask', 'raised_cosine', struct('edge', .15));
PsychMetal('DrawMaskedTexture', w, texture, mask, [], [100 100 500 500]);
PsychMetal('Flip', w);
```

Python signature:

```
draw_masked_texture(w, texture, mask=None, src_rect=None, dst_rect=None,
                    angle=0, filter_mode=1, global_alpha=None,
                    modulate_color=None, coverage=None)
```

MATLAB/Octave signature (use `[]` for defaults):

```
PsychMetal('DrawMaskedTexture', w, texture, mask, src, dst, angle, filter, alpha, tint, coverage)
```

- `mask`: an analytic `MakeMask` recipe or a one-channel image texture. Omit it
  for no coverage mask. Image values 0..1 mean transparent..opaque; uint8 images
  use 0..255. An image mask is always sampled with bilinear filtering.
- `coverage`: optional analytic recipe to multiply an image mask. Supplying an
  analytic recipe twice is rejected. See GPU-MASKS.md for geometry/edge units.
- `src`: one rectangle in source image pixels, wholly inside the image, with
  positive width/height. Default: whole image. Mirrored/outside crops are rejected.
- `dst`: one positive rectangle in target pixels; default: the crop's native
  pixel size centred on the target. Image dimensions and mask texture dimensions
  may differ. Destination coordinates are bounded to ±1,000,000.
- `angle`: clockwise degrees about the destination centre. Image and mask rotate
  together. Coverage spans the destination, independently of the source crop.
- `filter`: 0 nearest, 1 bilinear for image sampling. No mipmaps/anisotropic mode.
- `alpha` and `tint`: follow the window's ColorRange, initially 0..255. Tint
  multiplies RGB and alpha; global alpha must be within ColorRange. Source alpha,
  tint alpha, global alpha, image coverage and analytic coverage multiply.

The current blend mode and clip apply. Alpha/additive modes weight the source by
coverage; straight-source copy mode copies RGB wherever coverage is nonzero,
with coverage in alpha (it does not fade RGB against the existing background).
Offscreen sources and targets retain the engine's premultiplied alpha convention.
A source cannot also be the current drawing target. Mask images must be uploaded
one-channel textures, not offscreen windows.

The exact source and mask versions are retained when the draw is queued, then
through GPU completion. Updating or closing either handle cannot change an already
queued draw. Partial in-place updates are rejected while that texture is queued;
full updates may allocate another version. Native timelines capture both image
and mask resources; their animation tracks currently control procedural stimuli
only, so masked images replay as static scene items.

Colour values follow ordinary DrawTexture: no new ICC, transfer-function or HDR
metadata conversion is introduced. Use measured Linearize settings when required;
values are sampled/blended into the existing target and encoded by its final pass.
Do image loading/creation and calibration before a timing-critical trial.

## Demonstration and acceptance

Mac Python: `python python/masked_image_demo.py --seconds 20` with this package
on Python's path. MATLAB/Octave: `PsychMetalMaskedImageDemo(20)` or
`PsychMetalMaskedImageDemo(20, 'image.png')` after adding this folder to the path.
The optional file is kept at its original resolution. The Python/phone version
has a built-in colour image, so it needs no file picker or additional dependency.

Top panels: original, Gaussian. Bottom: annulus, raised cosine. Hold and drag any
panel with the mouse or one finger; release to leave it. Escape / three fingers
exits. No overlay text is placed near the phone's camera island.

CPU tests exercise the actual queue's snapshots, resource ownership, crop/filter/
tint validation and noncontiguous inputs. Both real front ends run against a
scripted contract-only engine. The real Metal fixture checks crops, rotation,
nearest/bilinear filtering, grayscale, multiplicative coverage, straight and
premultiplied sources, blend modes, and 8/10-bit/float targets. Execution of that
fixture and Mac/iPhone/iPad visual/timing tests remain pending: the development
execution environment has no accessible Metal GPU. Fresh iOS wheels/app build
are also required before the phone menu entry can run on a device.
