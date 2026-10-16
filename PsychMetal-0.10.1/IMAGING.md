# Reusable GPU imaging pipelines — 0.10.1

Prepared chains operate on textures without copying the image through CPU memory.
Outputs keep the source dimensions. Shader/pipeline preparation happens once;
processing submits ordered render passes on the engine's Metal queue.

```python
pipeline = pm.create_image_pipeline(w, [
    {'type':'gaussian', 'sigma':2},
    {'type':'exposure', 'stops':1},
    {'type':'color_matrix', 'matrix':np.eye(3)},
])
output = pm.process_image(w, pipeline, source)
# Animation: update source, then safely replace the existing output handle.
output = pm.process_image(w, pipeline, source, output)
pm.draw_texture(w, output)
pm.close_image_pipeline(w, pipeline)
# Output texture remains valid until close_texture / close.
```

```matlab
ops={struct('type','gaussian','sigma',2),struct('type','exposure','stops',1)};
p=PsychMetal('CreateImagePipeline',w,ops);
out=PsychMetal('ProcessImage',w,p,source);
out=PsychMetal('ProcessImage',w,p,source,out);
PsychMetal('DrawTexture',w,out);
PsychMetal('CloseImagePipeline',w,p);
```

Operations (1..32 in a chain):

| Type | Parameters and behavior |
|---|---|
| gaussian | sigma .1..10 pixels; optional radius 1..31, default ceil(3*sigma). Explicit normalized, truncated separable kernel; clamped edges. Alpha-aware premultiplied filtering, straight-alpha output. |
| exposure | stops -16..16; multiply RGB by 2**stops. |
| color_matrix | 3x3 RGB transform, or 3x4 with additive bias in the last column. No implicit colour-space conversion or calibration. |
| convolution | Odd 1x1, 3x3 or 5x5 kernel, true convolution (kernel reversal), clamped edges; alpha copied from center. |
| affine | 2x3 inverse mapping from destination pixel-center coordinates to source pixel centers. Identity [[1,0,0],[0,1,0]]; positive translation samples farther right/down. Bilinear interpolation and clamped edges. |

Intermediate/output textures are RGBA16Float, with float arithmetic in the
shader; signed RGB and values above 1 are retained, limited to half-float range.
Alpha stays 0..1. This is not a float64/32-bit-per-channel computation library.
Ordinary gray sources replicate to RGB; premultiplied offscreen sources are
converted to straight alpha when sampled. Affine interpolation is in straight
RGBA; choose opaque inputs where transparent-edge colour is important.

Each pipeline pools at most four two-texture workspaces within 256 MiB logical
pixel storage. GPU commands and queued draws retain snapshots. A bounded two
second wait allows GPU users to finish before declaring a busy/full pool; held
outputs can keep a workspace occupied. Reuse destination handles and close
unused outputs. Large images can fit fewer workspaces and may serialize.
Closing a pipeline preserves existing outputs and in-flight GPU ownership.
Filtered outputs disallow in-place partial CPU updates: update the source and
reprocess, or replace the complete output texture. This avoids changing a
snapshot still read by the GPU. Program/handle errors leave the destination
unchanged; asynchronous GPU failure invalidates the graphics session.

Demos: PsychMetalImagingDemo, python/imaging_demo.py, GPU image processing on phone.
Real GPU pixel/performance acceptance remains pending. A standalone Metal test
covers extended exposure, matrix ordering, convolution direction, affine mapping
and blur boundaries when a GPU is available.
