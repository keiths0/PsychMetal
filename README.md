# PsychMetal

A direct macOS Metal replacement for Psychtoolbox's `Screen`, on Apple silicon.

PsychMetal replaces `Screen`. Window creation, presentation, drawing, the
clock, the mouse, the cursor and the keyboard are all Core Graphics, AppKit and
Metal directly, with no OpenGL anywhere in it as of 0.4.0. It does not use
`Screen('Flip')` and does not go through Vulkan or MoltenVK. It keeps `Screen`'s
argument formats, so replacing `Screen(` with `PsychMetal(` in existing code is
meant to work; it copies none of `Screen`'s implementation.

**Experimental research software, not a validated replacement for Psychtoolbox
timing.** Every timing figure in this repository is a software timestamp derived
from `MTLDrawable.presentedTime`. None of it has been checked against a
photodiode. Do that before trusting it in an experiment.

MIT licensed. **Psychtoolbox is not required to run PsychMetal**, and is not
bundled. It is required only by the three comparison files named `PTB*`, which
exist to measure Psychtoolbox so there is something to compare against.

One file is derived from Psychtoolbox: `PsychMetalDotDemo.m` is a port of
Psychtoolbox's `DotDemo.m` with the OpenGL drawing replaced by Metal. It carries
the original copyright and history, and its differences from the original are
listed in its header. Psychtoolbox is MIT licensed, as is this repository. No
other file here contains Psychtoolbox source.

## Layout

| | |
| --- | --- |
| `PsychMetal-0.4.0/` | the toolbox — add this folder to your path |
| `docs/` | measurements, specifications, and the Feedback Assistant report |
| `fblatency.m` | standalone Objective-C reproducer for the `preferredFrameLatency` bug in `docs/04_feedback_assistant_report.md`. Objective-C despite the `.m` extension — it is compiled with `clang`, not run in MATLAB |

Start with `PsychMetal-0.4.0/README.md`.

## What it measures

On a MacBook Air (M4, 15-inch), macOS 27.0 beta, Octave 11.3 with Psychtoolbox 3.0.22:

| | |
| --- | --- |
| Presentation rate | 60.000/s, zero skipped intervals |
| Interval stability | 84 ns across 300 frames (two timebase ticks) |
| Input sample → photons | 1.96 refreshes |
| Predicted vs confirmed onset | ~16 ns for immediate flips |

`docs/05_results.md` has the full record, including the manipulations that
turned out to do nothing and the conclusions that were retracted. Several
findings in earlier sections were measured in a configuration later shown to be
unreliable and are flagged where that applies.

## Open problems

- No photodiode validation of `presentedTime` against light onset.
- One refresh of compositor latency that no application-visible setting removes.
  Filed as Feedback Assistant item 2 in `docs/05_results.md` section 11.
- The first flip after an idle period is probably predicted a refresh late. The
  prediction assumes a committed frame appears two boundaries later, which holds
  for a continuous loop; with the queue drained it appears to be one. Two
  observations on different code paths, uncharacterised, and it applies to the
  start of a trial.
- Sporadic late presentations, 0.2 to 0.8% across runs.

Scheduled presentation more than three refreshes ahead was listed here as an
open problem through 0.3.0. It was fixed in 0.3.1 by deleting the library's own
scheduling; cadences 1 to 12 now measure 0 to 1% late. See `docs/05_results.md`
section 9e.
