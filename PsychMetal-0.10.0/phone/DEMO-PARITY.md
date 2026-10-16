# Demo coverage in the phone app

Public non-keyboard MATLAB/Octave demos have Python equivalents. All except the
minimal template and the stimulus API example are in the phone app, which runs
the shared Python programs. Keyboard and keyboard-queue demos are excluded.

| MATLAB / Octave | Python | Phone menu |
|---|---|---|
| PsychMetalShapesDemo | shapes_demo | Shapes |
| PsychMetalMinimalDemo | minimal_demo | (Mac only: the smallest program, a template) |
| PsychMetalMouseRectDemo | mouse_rect_demo | Moving rectangle |
| PsychMetalTextureDemo | texture_demo | Textures |
| PsychMetalBlobArrayDemo | blob_array_demo | Blob array |
| PsychMetalBlobDemo | blob_demo | A pulsing spot |
| PsychMetalGaborDemo | gabor_demo | Drifting stripes |
| PsychMetalDotDemo | dot_demo | Moving dots |
| PsychMetalNoiseDemo | noise_demo | Changing noise |
| PsychMetalStimulusDemo | stimulus_demo | (Mac only: an example of the procedural stimulus calls) |
| PsychMetalHiddenRingDemo | hidden_ring_demo | Hidden ring |
| PsychMetalMaskedImageDemo | masked_image_demo | Image through apertures |
| PsychMetalShaderDemo | shader_demo | Custom GPU spiral |
| PsychMetalModulationMatchDemo | modulation_match_demo | Matching flicker and sound |
| PsychMetalAudioDemo | audio_demo | Sound recorder |
| PsychMetalRecordDemo | record_demo | Record a stimulus (H.264, app-local file, then replay) |
| PsychMetalMovieDemo | movie_demo | Movie playback (bundled numbered sample with sound) |
| PsychMetalExportDemo | export_demo | Export a stimulus (standalone Metal canvas, app-local H.264 movie) |

Phone additions remain: the rotating rectangle ring and the optional Frame
timing test. The hidden ring, once four phone-only entries (still or scrolling,
one- or three-pixel noise), is now one demo in all three languages, with the
drift speed (0-5 pixels per frame) and cell size (1-5 pixels) as arguments on
the Mac and as choices on its start page on the phone; both default to 1.

Phone adaptations:
- Three fingers returns to the menu; the minimal demo now also checks Escape.
- The mask demo uses a second-finger press instead of Space to switch its carrier.
  Holding the finger does not repeatedly toggle. Three fingers exits.
- Mask/background squares fit the shorter screen dimension in portrait.
- Textures stack vertically on portrait screens; tinted copies stay within the
  display in both orientations. The blob still follows the finger freely.
- The sound demos use the same code on both: a finger on a button, the dial or
  the slider is the mouse button held there. On a phone held upright the
  matching demo's switches stack in rows. Both lay out inside the screen's safe
  area, clear of the camera housing and the home indicator.

`test_phone_demos.py` checks menu parity against the Python demo files and
checks the touch switch and portrait mask geometry, and runs both sound demos
by scripted finger on a portrait screen. Scripted tests do not
replace a visual run on the phone. Hardware validation remains to be done.

Inventory/readback/hardware probes are tests, not demonstration programs, and
remain available in the toolbox. Tests that require desktop-only functionality
are not exposed as broken menu entries on the phone.

The Diagnostic-mode Native timeline maps PsychMetalTimelineDemo to
`timeline_demo`; it intentionally presents fixed positions during playback.
