# PsychMetal 0.11.0

New drawing features, some corrections and two changes of behaviour, which is
why it is 0.11.0 and not a 0.10 patch. The details are in CHANGELOG.md; what was
checked, and what was not, is in VALIDATION.md.

## What changed

- **Rotation and transforms.** Every drawing command takes an angle, in
  degrees clockwise, as its last argument (Python `angle=`; `rotation=` for
  draw_gabor, whose `angle` is the orientation): rects, ovals, arcs, Gabors and
  noise about their own centres, dots and lines about their center, polygons,
  text, stimuli and shaders about theirs. In MATLAB/Octave it comes after all of
  Screen's own arguments, so Psychtoolbox calls keep their meaning. Translate,
  Rotate, Scale, PushMatrix, PopMatrix and LoadIdentity transform everything
  drawn into a window or offscreen window, so a group of shapes can be moved and
  turned as one. Done in Metal's vertex shaders; see GPU-STIMULI.md.
- **Porting from Psychtoolbox.** PTB-PORTING.md lists what to change in a
  Psychtoolbox program: Screen becomes PsychMetal, the gl transform commands
  lose their gl, and the few commands that differ.
- **Flip far ahead.** A Flip for the next refresh, right after a Flip given a
  time about 30 or more refreshes ahead, was dropped by the system: the waiting
  frame stayed up a refresh too long. Every frame is now handed over when it is
  flipped, however far ahead. A Flip without a time, made before a waiting
  frame's refresh, now waits until half a refresh before it, so a loop is held
  there instead of running ahead.
- **Recording.** The last frame of every recording was reported dropped though
  it was on the screen; it is now reported shown. The test-movie generator, broken
  in 0.10.1, works again. The record demo pauses on its first click and resumes
  the motion where it stopped, its Gabor fades into the background, and its
  report no longer treats virtual-clock times as display times. In a live
  recording at 6K the first one or two frames can still reach the screen a
  refresh late; the movie keeps them at their intended refreshes (MOVIES.md).
- **Displays.** `screens()` / `PsychMetal('Screens')` lists the active displays
  and the number OpenWindow takes for each. Display capture stays on by default.
- **Audio interruptions are errors.** After a call or Siri, headphones plugged in
  or out, a change of output device or the output stopping for over 50 ms,
  Play, Modulate, StartRecording and VoiceKey raise `PsychMetal:AudioInterrupted`
  until audio is closed and reopened. Before, they went on with a warning.
- **Housekeeping.** Two native commands nothing called were removed; public
  commands are unchanged. Release documents of earlier versions are no longer
  copied into this folder; they remain in their own release folders.

## Compatibility

A program written for 0.10.1 runs unchanged, with two differences in
behaviour that can matter: a sound call after an audio interruption now raises an error, and a
Flip without a time right after one far ahead now waits instead of returning at
once. The new angles are added after every argument a command took before, so
no existing argument moved. FillArc and DrawArc take a sixth argument, which they
refused before, and FillPoly a fourth (Screen's isConvex), which it ignores.
DrawDots, DrawLines, FrameOval and FrameArc now accept Screen's lenient, smooth,
penHeight and penStyle before the angle. A
custom shader may not define `XF` or anything beginning `pm`, which the engine
now uses (CUSTOM-SHADERS.md). Requirements are as for 0.10.1: Apple silicon and macOS 14 or later for
MATLAB and Python, macOS 26 for the supplied Octave 11.3 binary, iOS 15 for the
toolbox wheels and iOS 17 for the phone app. Add only this version folder to the
MATLAB/Octave path.

GitHub publication, PyPI upload and App Store submission are separate actions.
