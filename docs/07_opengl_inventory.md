# Screen subfunctions and what removing OpenGL would take

> **This is about Psychtoolbox's `Screen`, not about PsychMetal, and it is a
> survey rather than a plan.** It asks what it would cost to take OpenGL out of
> `Screen` itself, subfunction by subfunction. PsychMetal took the other road:
> it does not implement `Screen`'s surface, it replaces the subset an experiment
> actually calls, and it has had no OpenGL in it since 0.4.0. Read this for the
> inventory of what a full replacement would owe, which is still accurate, and
> not as a description of what PsychMetal does.

Taken from `PsychSourceGL/Source/Common/Screen/RegisterProject.c` on master, which
registers every `Screen` subfunction. Grouped by what a Metal replacement would
actually involve.

## First, a correction on the motivation

> "perhaps that will make the drawing fast enough that we meet the deadline for
> the next frame"

The measurements do not support this. Drawing is not what misses the deadline:

| | Measured |
| --- | --- |
| Draw time per frame (Screen calls) | 1.25 – 1.35 ms |
| GPU pass, IOSurface → drawable | ~1.6 ms |
| Refresh interval | 16.67 ms |
| Submit → presented, sustained | 29.8 ms (1.79 refreshes) |

Section 4 of `05_results.md` settles it: with `displaySyncEnabled` off the frame
reaches the display 2.6 ms after GPU completion, and with it on the same frame
takes 27.6 ms. The 25 ms difference is the frame **waiting**, not work. Removing
the blit would save perhaps 1–2 ms of GPU time out of a ~30 ms lead and would not
move the N+2 boundary at all.

There are good reasons to drop OpenGL — correct draw ordering, no dependency on
an API Apple deprecated in 2018, one surface instead of two, no GL/Metal interop
or fencing — but latency is not one of them. Worth being clear about before
spending months on it.

**Confirmed in 0.3.1**, when both paths still existed. Tier 1 was implemented
and `UseOpenGL` made the whole interop path skippable, so the prediction above
could be tested directly, and it held: with three drawables, interop on flips in 13.5 ms and interop off flips in
13.4, both at 60.000/s with zero skips. The fence alone measures 0.119 ms. The
one thing that did move the rate was the drawable count, which is not in this
table at all — see `05_results.md` 9b. The figures above were taken at two
drawables, where the loop sits on the deadline; they are the right order of
magnitude and the argument does not depend on them.

## Tier 1 — 2D primitives

The core of the work, and all expressible as instanced quads with a shape type in
the fragment shader. One pipeline covers the lot, and analytic antialiasing comes
free for the curved ones.

| Function | Notes |
| --- | --- |
| `FillRect` | done |
| `FrameRect` | outer minus inner test |
| `FillOval` / `FrameOval` | ellipse test in the fragment shader |
| `FillArc` / `DrawArc` / `FrameArc` | ellipse plus angle range |
| `DrawLine` / `DrawLines` | quad per segment; caps and joins need thought |
| `DrawDots` | one instance per dot, round or square; the high-count case |
| `FillPoly` / `FramePoly` | needs CPU triangulation, the only one that does |
| `glPoint` / `gluDisk` | legacy aliases, fall out of the above |
| `LineStipple` | state, not a primitive |

## Tier 2 — textures

| Function | Notes |
| --- | --- |
| `MakeTexture` | already partly done in PsychMetal |
| `DrawTexture` / `DrawTextures` | second pipeline, sampler state, rotation |
| `TransformTexture` | render-to-texture |
| `PreloadTextures` | residency hint |
| `GetOpenGLTexture` / `SetOpenGLTexture` / `SetOpenGLTextureFromMemPointer` | GL by definition; these disappear rather than being replaced |

## Tier 3 — text

`DrawText`, `TextBounds`, `TextSize`, `TextStyle`, `TextFont`, `TextColor`,
`TextBackgroundColor`, `TextMode`, `TextModes`, `TextTransform`.

Less bad than it looks on macOS: PTB already rasterises through Core Text in its
drawtext plugin and uploads the result, so the font machinery is not OpenGL. What
is OpenGL is the upload and the textured quad. A glyph atlas plus the Tier 2
pipeline covers it.

## Tier 4 — drawing state

| Function | Notes |
| --- | --- |
| `BlendFunction` | maps onto `MTLRenderPipelineDescriptor` blend fields, but Metal bakes blend state into the pipeline, so each distinct blend mode needs its own pipeline object built up front |
| `ColorRange` | arithmetic only |
| `glPushMatrix` / `glPopMatrix` / `glLoadIdentity` / `glTranslate` / `glScale` / `glRotate` | the fixed-function matrix stack; needs a CPU-side stack feeding a uniform |
| `DrawingFinished` | maps to a command buffer boundary |
| `SelectStereoDrawBuffer` | only if stereo is in scope |

The blend-state point is worth flagging early: it is the one place where Metal is
structurally less convenient than OpenGL, because `glBlendFunc` is a cheap state
change and a Metal pipeline switch is not.

## Tier 5 — framebuffer access

`GetImage`, `PutImage`, `CopyWindow`. Blits and readback; straightforward in
Metal but needs care over storage modes on Apple silicon.

## Tier 6 — already replaced

`OpenWindow`, `OpenOffscreenWindow`, `Close`, `CloseAll`, `Flip`,
`AsyncFlipBegin/End/CheckEnd`, `WaitUntilAsyncFlipCertain`, `WaitBlanking`,
`GetFlipInterval`, `GetFlipInfo`. PsychMetal covers the parts it needs; the async
flip family is not implemented.

## Tier 7 — no OpenGL, keep as is

`Screens`, `PixelSize`, `PixelSizes`, `Rect`, `WindowScreenNumber`, `Windows`,
`WindowKind`, `IsOffscreen`, `WindowSize`, `GlobalRect`, `DisplaySize`,
`Resolution`, `Resolutions`, `ConfigureDisplay`, `FrameRate`,
`NominalFrameRate`, `Preference`, `Computer`, `Version`, `GetMouseHelper`,
`SetMouseHelper`, `HideCursorHelper`, `ShowCursorHelper`, `ConstrainCursor`,
`ReadNormalizedGammaTable`, `LoadNormalizedGammaTable`, `LoadCLUT`,
`GetTimeList`, `ClearTimeList`, `GetWindowInfo`, `Null`.

About a third of the API needs nothing done to it.

## Tier 8 — meaningless without OpenGL

`BeginOpenGL`, `EndOpenGL`, `GetOpenGLDrawMode`, `OpenProxy`. These exist to hand
the user a GL context. They cannot be ported, only removed — and removing them
breaks every experiment that drops into raw OpenGL, which is a real population.

## Tier 9 — media

`OpenMovie`, `PlayMovie`, `GetMovieImage`, `CloseMovie`, `SetMovieTimeIndex`,
`GetMovieTimeIndex`, the whole video capture family, `CreateMovie`,
`AddFrameToMovie`, `FinalizeMovie`, `AddAudioBufferToMovie`, `ReadHDRImage`.
GStreamer decodes to a texture; only the upload path is GL.

## Tier 10 — the imaging pipeline, and the real obstacle

`HookFunction` and `PanelFitter`.

This is where PTB's GLSL lives: colour correction, gamma, CLUT, panel fitting,
stereo compositing, high-bit-depth output formats, and every user-installed hook.
`PsychImaging` is built on it. It is substantially larger than everything in
Tiers 1–5 combined, and every one of those shaders would have to be rewritten in
Metal Shading Language.

Any plan that ends at "PTB with no OpenGL" has to answer what happens to
`HookFunction`. A plan that ends at "PsychMetal draws its own primitives and does
not use the imaging pipeline" does not — but it is then a different, smaller
toolbox rather than a replacement backend.

## Suggested order

1. Tier 1 primitives — one pipeline, immediate payoff, proves the approach.
2. Tier 4 blend and matrix state — Tier 1 is not usable without it.
3. Tier 2 textures — covers most real stimulus code.
4. Tier 5 framebuffer access — needed for any screenshot or validation.
5. Tier 3 text.

Stopping after 1–3 gives something that can run a large fraction of simple
experiments with no OpenGL at all, which is a defensible end state and a
reasonable place to reassess.
