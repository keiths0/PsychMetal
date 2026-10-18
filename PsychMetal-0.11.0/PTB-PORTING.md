# Porting a Psychtoolbox program to PsychMetal

PsychMetal takes Screen's argument formats where it can, but it is not a
complete Psychtoolbox replacement, and it uses no OpenGL. This is what to change
in a Psychtoolbox (PTB) program. Python names are the same in snake_case
(`PsychMetal('FillRect', w, ...)` is `pm.fill_rect(w, ...)`).

## Every program

| Psychtoolbox | PsychMetal |
|---|---|
| `Screen('Command', ...)` | `PsychMetal('Command', ...)`, with the same command name unless listed below |
| `KbCheck`, `KbWait`, `KbName`, `KbQueueCreate` and the other `KbQueue*`, `GetSecs`, `WaitSecs`, `GetMouse`, `SetMouse`, `HideCursor`, `ShowCursor` | `PsychMetal('KbCheck')` and so on: one function for everything |
| `Screen('Close', w)`, `Screen('CloseAll')`, `sca` | `PsychMetal('Close', w)` |
| `Screen('Preference', 'SkipSyncTests', ...)`, `Priority` | not needed: there are no sync tests to skip, and presentation timing does not come from the main thread's priority |

## Names that change

| Psychtoolbox | PsychMetal |
|---|---|
| `Screen('glTranslate', w, tx, ty[, tz])` | `PsychMetal('Translate', w, tx, ty)` (tz, if given, must be 0) |
| `Screen('glRotate', w, angle[, rx, ry, rz])` | `PsychMetal('Rotate', w, angle)` (the axis, if given, must be [0 0 ±1]) |
| `Screen('glScale', w, sx, sy[, sz])` | `PsychMetal('Scale', w, sx, sy)` (sz, if given, must be 1) |
| `Screen('glPushMatrix', w)`, `Screen('glPopMatrix', w)`, `Screen('glLoadIdentity', w)` | `PsychMetal('PushMatrix', w)`, `('PopMatrix', w)`, `('LoadIdentity', w)` |
| `Screen('Close', texture)` | `PsychMetal('CloseTexture', w, texture)` |
| `Screen('AsyncFlipBegin', ...)` / `('AsyncFlipEnd', ...)` | `PsychMetal('QueueFlip', w, when)` queues a frame and returns at once; `('QueueResults', w)` reports them all |
| `Screen('FrameRate', w)` | `1 / PsychMetal('GetFlipInterval', w)` |
| `Screen('LoadNormalizedGammaTable', ...)`, PsychColorCorrection | `PsychMetal('Linearize', w, gamma or table)`: a pass that makes drawn values linear light, not the display's gamma table |
| `CreateProceduralGabor` + `Screen('DrawTexture', ...)` | `PsychMetal('DrawGabor', w, ...)`, or `MakeStimulus('grating')` + `DrawStimulus` |
| `CreateProceduralNoise`, noise images made with `rand` | `PsychMetal('DrawNoise', w, rect, seed, ...)`, or `MakeStimulus('noise')` + `DrawStimulus` |
| `DrawFormattedText(w, text, 'center', 'center', ...)` | `PsychMetal('DrawText', w, text, [], [], colour, size, font, wrapWidth)`: newlines separate lines, [] centres |
| `Screen('TextSize', ...)`, `('TextFont', ...)`, `('TextStyle', ...)` | no text state: pass size and font to DrawText and TextBounds |
| `PsychPortAudio(...)` | `OpenAudio`, `MakeSound`, `Play`, `StopSound`, `Modulate`, `StartRecording`, `AudioResults` and the rest; see AUDIO.md |

## PsychImaging

A Psychtoolbox program that opens its window with `PsychImaging('PrepareConfiguration')`,
`PsychImaging('AddTask', ...)` and `PsychImaging('OpenWindow', ...)` asks for
what PsychMetal sets with OpenWindow's options and Linearize:

| PsychImaging task | PsychMetal |
|---|---|
| `'FloatingPoint16Bit'`, `'FloatingPoint32Bit'` framebuffer | drawing and blending are in half floats whenever Linearize, an offscreen window or HDR is in use; otherwise in the frame's own 8 or 10 bits |
| `'EnableNative10BitFramebuffer'` | OpenWindow option `bitDepth`, 10 |
| `'DisplayColorCorrection'` (gamma, lookup table) | `PsychMetal('Linearize', w, gamma or table)` |
| `'EnableHDR'` | OpenWindow option `hdr` (HDR.md) |
| `'FlipHorizontal'` / `'FlipVertical'` (a mirror setup) | the transform, set once after OpenWindow: `Translate(w, width, 0)` then `Scale(w, -1, 1)` (or `Translate(w, 0, height)`, `Scale(w, 1, -1)`); everything drawn, text included, is mirrored |
| `'GeometryCorrection'`, `'UsePanelFitter'`, stereo modes, Bits# / VPixx output | not available |

Then open the window with `PsychMetal('OpenWindow', options)` instead.

## Arguments that differ

- **OpenWindow:** `[w, rect, ifi] = PsychMetal('OpenWindow', screen, background, drawableCount)`, or one options struct. The window is the whole display; there is no rect for a window in part of the screen, and no pixelSize or numBuffers. Screen numbers come from `PsychMetal('Screens')`, 0 the main display.
- **Flip:** `PsychMetal('Flip', w[, when])`. dontclear, dontsync and multiflip are not supported: each frame starts from the background colour. The fifth output is slipped refreshes, not the beam position.
- **BlendFunction:** a mode, not OpenGL factors: `'alpha'` for `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA`, `'add'` for `GL_SRC_ALPHA, GL_ONE`, `'copy'` for `GL_ONE, GL_ZERO`.
- **DrawText:** `(w, text, x, y, colour, size, font, wrapWidth, angle)`. Screen's 6th argument is the background colour; here it is the size. x and y are the top left.
- **MakeTexture:** the window and the image only; optimizeForDrawAngle, specialFlags and floatprecision are not taken (float images are kept as float).
- **SetMouse:** `PsychMetal('SetMouse', w, x, y)`, the window first.
- **KbCheck, KbWait:** no deviceNumber: macOS merges every keyboard, so all are read. KbWait takes untilRelease and pollInterval (KEYBOARD-QUEUE.md).
- **GetImage:** `(w[, rect])`, and only with a window opened with readback (READBACK.md).
- **Screens:** returns the display numbers and a struct of their names, sizes and rates.
- **Movies:** OpenMovie is the same; frames are drawn by number with `DrawMovieFrame`, or played with `PlayMovie` at a whole number of refreshes each. There is no `GetMovieImage` (MOVIES.md).
- **FillPoly:** Screen's isConvex is accepted and ignored: any polygon is filled by the even-odd rule.
- **DrawDots, DrawLines, FrameOval, FrameArc:** Screen's lenient, smooth (lines are always antialiased), penHeight and penStyle are accepted when they ask for what is drawn (penHeight equal to penWidth, penStyle 0) and refused otherwise.

## What is new here

Every drawing command takes a rotation angle after Screen's own arguments
(GPU-STIMULI.md), and Screen has no equivalent of `Clip`, `DrawNoise`,
`MakeStimulus`/`DrawStimulus`, `CreateShader`/`DrawShader`, `DrawMaskedTexture`,
`QueueFlip`, `PlayTimeline` or `StartMovieRecording`.

## Not available

Stereo drawing (`SelectStereoDrawBuffer`), OpenGL calls of any kind (`Screen('BeginOpenGL')`, moglcore),
PsychImaging's geometry correction and panel fitter,
`Screen('DrawTexture')` with a procedural shader from PTB, and vendor hardware
(VPixx, EyeLink, Cedrus): not yet. If a command is missing, `PsychMetal('?')`
lists those there are, and `PsychMetal('Command?')` describes one.
