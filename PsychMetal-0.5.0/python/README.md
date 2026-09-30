# psychmetal

Native Metal stimulus presentation on Apple silicon Macs, from Python, with an interface resembling Psychtoolbox's Screen. There is no OpenGL anywhere in the path. The same engine serves [PsychMetal](https://github.com/keiths0/PsychMetal) for MATLAB and Octave.

Install it into a virtual environment. Homebrew's Python (and any Python following PEP 668) refuses packages installed outside one:

```bash
python3 -m venv ~/venvs/psychmetal          # once
source ~/venvs/psychmetal/bin/activate      # in each new Terminal window
pip install psychmetal
```

Requires macOS 14 or later on Apple silicon, an arm64 Python 3.10 or later, and numpy.

```python
import psychmetal as pm

w, rect, ifi = pm.open_window(0, [0, 0, 0])
try:
    pm.fill_rect(w, [255, 0, 0], [100, 100, 300, 300])
    vbl, onset, flip_return, missed, slipped = pm.flip(w)
    pm.wait_secs(1)
finally:
    pm.close(w)
```

Each PsychMetal command is a function with the snake_case name and the same arguments, order and defaults as in MATLAB; MATLAB's `[]` is `None`. Colours run 0–255 by default. Key indices are 0-based (`kb_name('ESCAPE')` is 40). Several rectangles, dot positions and per-item colours keep MATLAB's 4xN, 2xN and 3xN/4xN orientation, and images are numpy arrays (H, W[, C]) in any memory layout, read without copying. `help(psychmetal)` covers threading, batching and the other details.

Demos and hardware checks (Gabors, dynamic noise, textures, dot motion, keyboard, an inventory of every command) are in the repository's [python folder](https://github.com/keiths0/PsychMetal/tree/main/PsychMetal-0.5.0/python).

Flip timestamps come from Metal's presentation reports, not a photodiode. See the repository for validation and its limits.

MIT license.
