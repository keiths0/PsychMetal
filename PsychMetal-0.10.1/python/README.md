# psychmetal

Native Metal stimulus presentation and Core Audio sound on Apple silicon Macs, from Python, with an interface resembling Psychtoolbox's Screen. There is no OpenGL anywhere in the path. The same engine serves [PsychMetal](https://github.com/keiths0/PsychMetal) for MATLAB and Octave.

Version 0.10.1 runs on Apple silicon Macs and in the separately built iPhone/iPad app. It has audio (sounds scheduled to the sample or to a frame, amplitude modulation on the same clock, recording and a voice key), native timelines with keyframes and live control, analytic masks, masked images, custom fragment shaders, and environment reports. See AUDIO.md, TIMELINE.md, GPU-MASKS.md, MASKED-IMAGES.md and CUSTOM-SHADERS.md in the source tree.

Install it into a virtual environment. Homebrew's Python (and any Python following PEP 668) refuses packages installed outside one:

```bash
python3 -m venv ~/venvs/psychmetal          # once
source ~/venvs/psychmetal/bin/activate      # in each new Terminal window
pip install /path/to/PsychMetal-0.10.1       # the source folder, or a release wheel
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

Demos and hardware checks (Gabors, dynamic noise, textures, dot motion, keyboard, a live spectrogram with a recorder, phase and frequency matching of flicker and sound, an inventory of every command) are in the repository's [python folder](https://github.com/keiths0/PsychMetal/tree/main/PsychMetal-0.10.1/python).

Flip timestamps come from Metal's presentation reports, and sound times from Core Audio's, not from a photodiode or a microphone. See the repository for validation and its limits.

```python
info = pm.open_audio()
beep = pm.make_sound(pm.tone(1000, 0.05, info['rate']))
pm.play(beep, when=pm.get_secs() + 0.5)
print(pm.audio_results(wait=1))     # when it started, on the sample nearest the time asked
pm.close_audio()
```

`pm.play_timeline(w, frames, tracks)` replays a queued scene natively, with no
per-frame Python calls; `timeline_demo.py` shows it. `pm.draw_masked_texture`
applies analytic GPU coverage to an image; `masked_image_demo.py` shows it.
`pm.stop()` ends a running experiment, including native playback and waits.

MIT license.
