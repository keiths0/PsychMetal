# Development probes

Measurements made while PsychMetal was built: sleep and wake-up precision, the
compositor's path, drawable acquisition, input latency, latching and tearing
with display sync off, mixed cadences, refresh-rate comparisons, scheduling
sweeps, warm-up length, Screen('Flip', when) behaviour, and comparisons with
Psychtoolbox (`comparisons/`).

They are MATLAB only, they are not part of a release, and no test runs them.
Several use presentation controls that 0.9.0 removed (PrepareFlip, PresentNow,
PrefetchDrawable, SetDisplaySync, waitForConfirm, LinkInfo, captureDisplay), so
run them with the 0.8.1 package on the path:

```matlab
addpath(fullfile(getenv('HOME'),'Developer','PsychMetal','PsychMetal-0.8.1'),'-begin');
addpath(fullfile(getenv('HOME'),'Developer','PsychMetal','probes'));
PsychMetalTearTest(20)
```

What they found is in `docs/05_results.md` and the CHANGELOG.

## Python: Flip with a time (0.10)

`flip_when_v1.py`, `flip_when_v2.py` and `flip_when_v3.py` measure when frames
given a time with `pm.flip(w, when)` are shown, read from the display's own
reports. v3 flips a frame a set number of refreshes ahead, then frames for the
next refresh at once; it is the probe for a frame the system drops after a wait
of about 30 refreshes or more. They use the 0.10.1 package by default; run them
from this folder's parent, after `make all` in that release:

```
python3 probes/flip_when_v3.py 15 20 30 60
PM_VERSION=0.10.0 python3 probes/flip_when_v3.py
```

`PM_HOLD_LIMIT=<refreshes>` changes the engine's 15-refresh hold limit for
v3's tests (0.10.1 only; 0.11.0 removed the hold it changed).

`record_unreported_v1.py`, `record_unreported_v2.py` and `record_unreported_v3.py`
run `python/record_demo.py` unchanged and list every frame the display did not
report shown, with (v2, v3) when the frames around it were committed, asked for,
finished on the GPU and shown. v3 repeats the demo (`python3
probes/record_unreported_v3.py 10`). They found the last frame of every recording
reported dropped though it was shown, fixed in 0.11.0.
`record_unreported_v4.py` is v3 for the 0.11.0 record_demo, which pauses on its
first click; `record_start_v1.py` shows where the time went for the first frames
of a recording (drawable wait, CPU encoding, GPU pass, commit and display).
`flip_phase_v1.py` waits until a chosen fraction of a refresh, flips, and reads
how many refreshes later the frame was shown, without and with a movie being
recorded: how late in a refresh a frame can be committed and still be shown when
flip says.
