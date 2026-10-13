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
