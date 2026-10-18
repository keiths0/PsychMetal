# PsychMetal 0.11.0 validation — October 17–18, 2026

What was checked for this release, on what, and what was not. It was developed
and first tested as 0.10.2; the results below dated October 17 were obtained
with those sources, which differ from 0.11.0 only in the version number, unless
marked otherwise. On the 0.11.0 folder itself, October 18: `make all`, then
`make test` with every regression check passed and nothing skipped (GPU pixel
fixtures including transforms, the five test movies, both front ends, the
sanitizer runs); the phone app built from fresh 0.11.0 wheels and ran.
Python inventory on 0.11.0: 307 of 307 checks over 129 commands; the Python
shapes demo, with the round dots restored, 1200 frames at 60 Hz.
After that, the transform commands lost their gl prefix (Translate, Rotate,
Scale, PushMatrix, PopMatrix, LoadIdentity) and the angles of DrawDots,
DrawLines, FrameOval and FrameArc moved past Screen's own arguments. Keith then
rebuilt (`make all`), reran `make test`, the inventories and the shapes demos,
rebuilt the phone wheels and app, and reported on October 18 that everything
worked; the individual counts of that final round were not copied into this
record. Validation
records of earlier releases are in their own release folders. Hardware here is
Keith's Mac with a Pro Display XDR at 6016 x 3384 and 60 Hz (its link is
compressed, DSC), and his iPhone.

## On the Mac

- `make test` with nothing skipped, October 17, on the final sources: every
  regression check passed,
  including the GPU pixel fixtures and the five test movies (ProRes 4444 and
  422, H.264, HEVC, sideways), each written and read back frame by frame. It is
  the first complete run with the movie fixtures since 0.10.0: 0.10.1 was
  validated with `--skip-media-fixtures`, which hid that its test-movie
  generator could not read its own movies back.
- `make test` again after rotation and transforms were added, October 17: every
  check passed with nothing skipped, including the new GPU pixel test
  (tests/test_transform_metal.mm: a shape's own turn, Rotate, Translate and
  Scale give the shapes they should, edges, pens and line widths included).
- Python inventory, after transforms: 307 of 307 checks over 129 commands on the
  6K display, including every drawing function's angle, the transform's
  composition and rejections, and a translated, scaled and turned rect read back
  from the screen where it should be. Before transforms: 299 of 299 over 122,
  including a frame flipped 30 refreshes ahead followed by three for the next
  refreshes (30, 1, 1 and 1 refreshes apart) and the display list (one display).
- Python shapes demo with rotation: 1200 frames at 60 Hz, every panel turning.
  The dots panel was then changed back to round dots running along their
  contour, with the contour turning; that version ran 1200 frames on 0.11.0.
- MATLAB R2026a and Octave inventories (`PsychMetalInventoryTest`): 297 of 297
  checks over 115 commands in each before transforms, including the
  after-a-wait check (30, 1, 1, 1 refreshes, every frame shown) and the display
  list. With transforms and the final names: reported working by Keith on
  October 18 (counts not recorded); the scripted-engine Octave run, 305 of 305
  over 122 commands, passed with the same sources.
- Flip far ahead (`probes/flip_when_v3.py` in the repository), 20 trials at
  waits of 15, 20, 30 and 60 refreshes, each followed by five frames for the
  next refreshes: 0 wrong. 0.10.1 got every trial at 30 and 60 wrong (the first
  following frame dropped, status 1).
- Commit phase (`probes/flip_phase_v1.py`): a frame committed at 0.0 to 0.9 of a
  refresh was shown when Flip said, 80 of 80 without recording; while recording
  at 6K, 78 of 80, the 2 late ones committed at 0.94.
- Recording (`probes/record_unreported_v3.py`, `_v4.py`): over 20 runs of the
  record demo with the live clock, every frame was reported shown and the
  recorder counted none unreported; the paused frame held 30 refreshes in every
  run. The live demo: 181 of 181 frames reported, clicks within 0.02 ms of their
  scheduled times.
- Late start of a live recording (`probes/record_start_v1.py`): in about half the
  runs the first one or two frames reached the screen a refresh late. Warming
  the copy up and aligning the first commit to a refresh were tried and
  removed; neither changed it. Documented in MOVIES.md as a known limit. Once,
  early on, the frame flipped half a second ahead was dropped while recording;
  it has not recurred in the 20 probe runs since, and its cause is not known.

## On the iPhone

For 0.11.0: built from fresh 0.11.0 wheels and run, October 18. The shapes
demo (everything turning, labels clear of the rounded corners), the ring of
rectangles, Drifting Gabors (renamed from Drifting stripes) and the Diagnostic
mode switch, whose off track is now visible, were checked by eye. Before
transforms, the app was rebuilt from wheels of these sources and run. The record demo paused on its
first click and resumed where it stopped. Siri during a sound demo stopped it
with the interruption message, at the next sound the demo started.

## Software checks

Front ends against the scripted engine (Python, Octave): inventories, demos,
phone menu and demos. Audio host under AddressSanitizer/UndefinedBehaviorSanitizer
and ThreadSanitizer, including the new interruption rule (a reported loss and a
200 ms stop in the output). Transforms through both front ends (call order,
the transform restored after a turned draw, argument limits), the native draw
functions against stubs, and the custom shader wrapper with the new names. Engine type checks against stub headers for macOS,
iOS and the simulator.

## Limits

No photodiode, microphone or loopback measurement: presentation and sound times
are those the system reports. One display at 60 Hz: other refresh rates,
ProMotion, a second display (Screens has listed only one) and iPad are
untested. Text that is turned is a Core Text mask turned and sampled bilinearly
by the GPU, not rendered at the angle; how it looks has been judged by eye only.
Siri muting the output while it keeps running cannot be detected.
App builds are unsigned local builds, not an App Store submission.
