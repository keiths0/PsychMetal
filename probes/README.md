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
v3's tests (0.10.1 reads it; nothing else should set it).
