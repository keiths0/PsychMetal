# Custom Metal fragment stimuli — 0.8.0 development

Compile a program before the trial, then draw it with sixteen scalar parameters.
This shares the native Metal engine across Python, MATLAB/Octave and iOS.
There is no video or audio subsystem.

```metal
float4 psychmetal_main(float2 pixel, float2 uv, constant float4* parameters) {
    float frequency = parameters[0].x;  // cycles per display pixel
    float phase = parameters[0].y;      // radians, supplied by caller
    float value = .5 + .5*cos(6.28318530718*frequency*pixel.x + phase);
    return float4(value, value, value, 1);
}
```

Python:

```python
shader = pm.create_shader(w, source)
pm.draw_shader(w, shader, [.025, phase], dst_rect=[100,100,500,500],
               mask=pm.make_mask('gaussian'))
pm.flip(w)
pm.close_shader(w, shader)
```

MATLAB/Octave:

```matlab
shader = PsychMetal('CreateShader', w, source);
PsychMetal('DrawShader', w, shader, [.025 phase], [100 100 500 500], ...
           PsychMetal('MakeMask','gaussian'));
PsychMetal('Flip', w);
PsychMetal('CloseShader', w, shader);
```

`pixel` is centred destination-local position in display pixels, positive right
and down; `uv` runs 0..1 across the destination. Output is straight (unmultiplied)
RGBA in normalized 0..1, independent of ColorRange. RGB/alpha are clamped; pixels
with nonfinite output are discarded. Parameters are four float4s, padded with
zeros from up to sixteen finite host doubles, bounded to ±1,000,000 and converted
to float at draw time. There is no implicit clock: supply phase/time explicitly.

The engine owns vertex geometry, the clip rect, blend mode, masks and target.
Optional image and analytic coverage use the same DrawStimulus conventions;
all alpha factors multiply. Source code provides the exact function above,
with no custom vertex function, buffer binding, texture binding or compute pass.
Metal headers/helpers may be used. This is an advanced trusted-program interface,
not a sandbox: unbounded/expensive GPU code can miss deadlines or fail a command
buffer. Compilation alone does not certify physical timing or scientific accuracy.

CreateShader compiles all target/blend combinations upfront (current 8/10-bit
window, float linearization, premultiplied offscreen). Live identical source
programs share a weak pipeline cache; at most 64 shader handles per session,
256 KiB UTF-8 source per program, and the cache is bounded to 64 keys. Compiler
errors preserve the user-source filename/line and create no handle. Parameters
and mask/source versions are snapshotted at draw; closing a handle leaves queued
frames and captured timelines valid. Handles expire permanently on close/session
end. Reopen and recreate programs for another output bit depth.

Custom shader draws replay as static items in native timelines; built-in timeline
tracks and live controls currently target procedural stimuli only. Host-side
DrawShader calls may change parameters between frames, like ordinary drawing.
General shader keyframe tracks and user textures are not part of this first ABI.

Run `PsychMetalShaderDemo(20)` or `python python/shader_demo.py --seconds 20`.
The source is shared between demos: custom-shader-demo.metal. GPU pixel, target,
compile-error and visual/timing acceptance requires an accessible Metal device.
