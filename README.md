# PsychMetal direct IOSurface attachment experiment

PsychMetal is open-source software distributed under the MIT License.
Psychtoolbox is a required external dependency and is not bundled with this
repository. This distribution contains no Psychtoolbox source code or adapted
Psychtoolbox demos.

This prototype does not call `Screen('Flip')` and does not perform the former
full-frame OpenGL blit. During `OpenWindow`, it replaces the color attachment of the
stable PTB offscreen window's FBO with IOSurface A. `Flip` presents that surface
through Metal and changes the same FBO's attachment to IOSurface B for the next
round of ordinary PTB drawing commands.

Run the fullscreen test:

```matlab
cd('/path/to/PsychMetal')
PsychMetalDirectDemo(600)
```

The PTB-like synchronous interface keeps one stable drawing handle:

```matlab
[w, rect, ifi] = PsychMetal('OpenWindow');             % Native fullscreen from borderless window.
% Or select display 1: [w, rect, ifi] = PsychMetal('OpenWindow', 1);
Screen('DrawDots', w, ...);
tex = PsychMetal('MakeTexture', w, imageMatrix);
Screen('DrawTexture', w, tex, [], destination, angle, 1);
[vbl, onset, flipTime, missed, beampos] = PsychMetal('Flip', w);
history = PsychMetal('Diagnostic', w);
PsychMetal('Close', w);
```

# Converting a basic Psychtoolbox program

Continue using `Screen` for drawing and for ordinary texture operations. Replace
only window creation, matrix-to-texture creation, presentation, and final window
cleanup:

| Standard Psychtoolbox call | PsychMetal replacement |
| --- | --- |
| `[w, rect] = Screen('OpenWindow', screenNumber, background);` | `[w, rect, ifi] = PsychMetal('OpenWindow', screenNumber);` |
| `tex = Screen('MakeTexture', w, image, ...);` | `tex = PsychMetal('MakeTexture', w, image, ...);` |
| `[vbl, onset, flipTime, missed, beampos] = Screen('Flip', w);` | `[vbl, onset, flipTime, missed, beampos] = PsychMetal('Flip', w);` |
| `Screen('CloseAll');` | `PsychMetal('Close', w);` |

For example, change this:

```matlab
[w, rect] = Screen('OpenWindow', max(Screen('Screens')), 0);
tex = Screen('MakeTexture', w, imageMatrix);
Screen('DrawTexture', w, tex);
vbl = Screen('Flip', w);
Screen('Close', tex);
Screen('CloseAll');
```

to this:

```matlab
[w, rect, ifi] = PsychMetal('OpenWindow', max(Screen('Screens')));
tex = PsychMetal('MakeTexture', w, imageMatrix);
Screen('DrawTexture', w, tex);
vbl = PsychMetal('Flip', w);
Screen('Close', tex);
PsychMetal('Close', w);
```

All drawing calls—including `FillRect`, `FillOval`, `DrawDots`, `DrawTexture`,
`DrawText`, blending, and drawing into the returned `w`—remain ordinary
`Screen` calls.

This is intentionally not a general drop-in replacement for every `Screen`
mode. `OpenWindow` accepts only an optional screen number and always opens
fullscreen. `Flip` accepts only `w`; scheduled `when`, `dontclear`, `dontsync`,
multiflip, wait-frame, asynchronous-flip, stereo, HDR, and specialized-hardware
modes are not implemented. Close PsychMetal with `PsychMetal('Close', w)` before
calling `Screen('CloseAll')` for any unrelated PTB resources.

The returned `rect` is expressed in physical framebuffer pixels. Fullscreen first
creates an exact borderless display-sized window, then enters the native macOS
fullscreen Space. Starting borderless avoids an erroneous title-bar-sized inset
while retaining the native fullscreen state needed for possible Game Mode activation.
On a Retina display this avoids drawing a smaller image and enlarging it in the
final Metal pass.

On a notched MacBook, showing pixels beside the notch also requires the Octave
host application to opt out of display-safe-area compatibility mode. PsychMetal
cannot change that process-level `Info.plist` policy after Octave has launched.

`Flip` alternates the private Metal/IOSurface buffers, waits for the display
link to accept the frame, and uses the basic `Screen('Flip')` output order.
To maintain one presentation per refresh, Metal keeps frames queued in advance.
On the tested system, the display link normally accepts a frame with a target
approximately two refresh intervals in the future. At that point the future
target is known, but the actual `presentedTime` cannot exist yet: Metal reports
it through a completion handler only after the frame has been presented.

Consequently, the VBL and onset values returned immediately by `Flip` are the
calibrated projected target presentation time, not a confirmed timestamp.
Waiting inside every `Flip` until the actual timestamp arrived would stall the
calling MATLAB/Octave loop while the queued frame crossed those future
refreshes. In testing, this prevented subsequent frames from being submitted
far enough ahead and reduced the presentation rate. PsychMetal therefore saves
the later confirmations asynchronously. `PsychMetal('Diagnostic', w)` waits
outside the presentation loop for outstanding callbacks and returns one record
for every Flip, including `projectedTimestamp`, `actualTimestamp`, status,
display-link tick, and prediction error. An unavailable Apple confirmation is
reported as `NaN` and is not by itself evidence that the physical frame was
missed.

Only one-presentation-per-refresh operation is supported; there is no `when`,
`waitframes`, `dontclear`, or asynchronous flip mode.
The complete comparison returned by `Diagnostic` allows isolated one-refresh
confirmation discrepancies to be identified by flip number.

Supported target use: draw to `w`. Do not pass `w` as the source texture of a
`DrawTexture` call: PTB's internal source-texture field still refers to the
detached texture it originally created. Independently created PTB textures can
still be drawn onto `w` normally.

# Installing from the distributed folder

The `PsychMetal` folder is self-contained. After unzipping it, change into that
folder. The supplied Apple-silicon binaries normally allow immediate use without
compiling:

```matlab
addpath(pwd);
savepath;  % Optional: retain the path for future sessions.
```

Add the unzipped `PsychMetal` folder itself to the MATLAB or Octave path. There
is no separate runtime or build-output directory.

## macOS security after downloading

The supplied MEX files carry the ad-hoc signatures produced by Apple's linker,
but they are not signed with an Apple Developer ID or notarized. A web browser
normally marks a downloaded zip with macOS's quarantine attribute, so Gatekeeper
may prevent MATLAB or Octave from loading the extracted MEX file.

The safest solution is to inspect the source and rebuild it locally as described
below. If you trust this download and want to use the supplied binaries, remove
the quarantine attribute only from the extracted PsychMetal folder:

```sh
cd /path/to/PsychMetal
xattr -dr com.apple.quarantine .
```

Do not disable Gatekeeper globally. Re-signing should not normally be necessary,
because both included ARM64 binaries are already linker-signed. Their signatures
can be checked with:

```sh
codesign --verify --verbose=2 PsychMetalCore.mex
codesign --verify --verbose=2 PsychMetalCore.mexmaca64
```

# Rebuilding

PsychMetal uses one shared Objective-C++ source file but separate host binaries:

```text
PsychMetalCore.mex       GNU Octave on Apple silicon
PsychMetalCore.mexmaca64 MATLAB on Apple silicon
```

From inside the unzipped `PsychMetal` folder, rebuild both binaries in place:

```sh
./build_all.sh
# or: make all
```

The rebuilt binaries are written into the same folder as `PsychMetal.m`:

```text
PsychMetalCore.mex       GNU Octave on Apple silicon
PsychMetalCore.mexmaca64 MATLAB on Apple silicon
```

MATLAB selects `PsychMetalCore.mexmaca64`; Octave selects
`PsychMetalCore.mex`.

Or build one host explicitly:

```sh
make octave
make matlab
```

If MATLAB is installed somewhere other than the default used by the Makefile:

```sh
make matlab MATLAB_ROOT=/Applications/MATLAB_R2026a.app
```

A source distribution includes `PsychMetalCore.mm`, `PsychMetal.m`, the
Makefile, build scripts, README, and an original direct demo. Prebuilt `PsychMetalCore.mex` and
`PsychMetalCore.mexmaca64` files are included for convenience, but they do
not replace the source or reproducible build instructions.

For maintainers working from the parent development directory, `make package`
rebuilds both binaries and refreshes the clean `dist/PsychMetal` folder that is
intended to be zipped.
