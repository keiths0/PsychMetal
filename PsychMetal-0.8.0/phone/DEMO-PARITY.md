# Demo coverage in the phone app

All eleven public non-keyboard MATLAB/Octave demos have Python equivalents included in
the phone app. The app runs those shared Python programs rather than separate
copies. Keyboard and keyboard-queue demos are excluded.

| MATLAB / Octave | Python | Phone menu |
|---|---|---|
| PsychMetalMinimalDemo | minimal_demo | One rectangle |
| PsychMetalMouseRectDemo | mouse_rect_demo | Moving rectangle |
| PsychMetalTextureDemo | texture_demo | Textures |
| PsychMetalBlobArrayDemo | blob_array_demo | Blob array |
| PsychMetalBlobDemo | blob_demo | A pulsing spot |
| PsychMetalGaborDemo | gabor_demo | Drifting stripes |
| PsychMetalDotDemo | dot_demo | Moving dots |
| PsychMetalNoiseDemo | noise_demo | Changing noise |
| PsychMetalStimulusDemo | stimulus_demo | Noise through a mask |
| PsychMetalMaskedImageDemo | masked_image_demo | Image through apertures |
| PsychMetalShaderDemo | shader_demo | Custom GPU spiral |

Phone additions remain: the rotating rectangle ring, still/scrolling hidden
rings with one- and three-pixel noise, and the optional Frame timing test.

Phone adaptations:
- Three fingers returns to the menu; the minimal demo now also checks Escape.
- The mask demo uses a second-finger press instead of Space to switch its carrier.
  Holding the finger does not repeatedly toggle. Three fingers exits.
- Mask/background squares fit the shorter screen dimension in portrait.
- Textures stack vertically on portrait screens; tinted copies stay within the
  display in both orientations. The blob still follows the finger freely.

`test_phone_demos.py` checks menu parity against the Python demo files and
checks the touch switch and portrait mask geometry. Scripted tests do not
replace a visual run on the phone. Hardware validation remains to be done.

Inventory/readback/hardware probes are tests, not demonstration programs, and
remain available in the toolbox. Tests that require desktop-only functionality
are not exposed as broken menu entries on the phone.

The Diagnostic-mode Native timeline maps PsychMetalTimelineDemo to
`timeline_demo`; it intentionally presents fixed positions during playback.
