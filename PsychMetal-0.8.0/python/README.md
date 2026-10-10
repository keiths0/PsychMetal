# psychmetal

Native Metal stimulus presentation on Apple silicon Macs, from Python, with an interface resembling Psychtoolbox's Screen. There is no OpenGL anywhere in the path. The same engine serves [PsychMetal](https://github.com/keiths0/PsychMetal) for MATLAB and Octave.

Version 0.8.0 is available for Mac and the separately built iPhone/iPad app. It adds native timelines with keyframes/live control, analytic masks, masked images, custom fragment shaders and phone report sharing. See TIMELINE.md, MASKED-IMAGES.md, CUSTOM-SHADERS.md and phone/README.md in the source tree. Hardware acceptance remains pending.

Install it into a virtual environment. Homebrew's Python (and any Python following PEP 668) refuses packages installed outside one:

```bash
python3 -m venv ~/venvs/psychmetal          # once
source ~/venvs/psychmetal/bin/activate      # in each new Terminal window
pip install /path/to/PsychMetal-0.8.0    # build this version
```

Requires macOS 14 or later on Apple silicon, an arm64 Python 3.10 or later, and numpy.

```python
import psychmetal as pm

with pm.open_window(0, [0, 0, 0]) as (w, rect, ifi):
    pm.fill_rect(w, [255, 0, 0], [100, 100, 300, 300])
    vbl, onset, flip_return, missed, slipped = pm.flip(w)
    pm.wait_secs(1)
```

Each PsychMetal command is a function with the snake_case name and the same arguments, order and defaults as in MATLAB; MATLAB's `[]` is `None`. Colours run 0–255 by default. Key indices are 0-based (`kb_name('ESCAPE')` is 40). Several rectangles, dot positions and per-item colours keep MATLAB's 4xN, 2xN and 3xN/4xN orientation, and images are numpy arrays (H, W[, C]) in any memory layout, read without copying. `help(psychmetal)` covers threading, batching and the other details.

Demos and hardware checks (Gabors, dynamic noise, textures, dot motion, keyboard, an inventory of every command) are in the repository's [python folder](https://github.com/keiths0/PsychMetal/tree/main/PsychMetal-0.6.0/python).

Flip timestamps come from Metal's presentation reports, not a photodiode. See the repository for validation and its limits.

MIT license.


0.8.0 adds `pm.play_timeline(w, frames, tracks)` for native replay
of a queued scene. `timeline_demo.py` measures refresh, then runs fixed Gaussian
flicker with no per-frame Python calls. `pm.stop()` also cancels native playback.
See TIMELINE.md in the source tree for track layout and presentation semantics.
The phone app needs freshly built 0.8.0 extension wheels before using this API.

## 0.8.0: masked still images

Use `pm.draw_masked_texture(w, texture, pm.make_mask('gaussian'))` to apply
analytic GPU coverage to an image without resizing its pixels on the CPU.
Image masks can multiply analytic masks. See MASKED-IMAGES.md and run
`python masked_image_demo.py` for the draggable four-aperture demonstration.
Video and audio are deferred to future releases.
