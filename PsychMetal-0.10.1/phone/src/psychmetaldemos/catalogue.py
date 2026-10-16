"""Public educational demonstrations. Developer checks remain in the toolbox."""
GROUPS = [
    ('Shapes and textures', [
        ('HDR brightness', 'hdr_demo', 'hdr_demo', {'flicker_hz':16},
         'A circular 7 by 7 grid compares every pair of brightness levels from half to sixteen times SDR white. Row and column levels alternate near your chosen rate (16 Hz target by default) using equal whole-frame holds; identical pairs on the diagonal stay steady. Smaller steady circles below provide references. Tap the Slower/Faster controls on the running demonstration to change the rate. The displayed frame-grid rate is the attainable rate. Current/potential headroom updates live; a star marks a reference above current headroom. Requires an HDR/EDR-capable display; unsupported screens show an error instead of silently using SDR. Brightness above available headroom clips. These are relative values, not calibrated nits. Three fingers returns.'),
        ('GPU image processing', 'imaging_demo', 'imaging_demo', {},
         'Compare an original texture with Gaussian blur, sharpening and a colour-matrix-plus-blur chain. All processing runs on the GPU with reusable intermediate textures. Three fingers returns.'),
        ('Shapes', 'shapes_demo', 'shapes_demo', {},
         'Every kind of shape PsychMetal draws, one panel each and labelled with the call that draws it: rectangles, ovals, polygons, lines, dots, arcs, text, a Gabor patch and translucent colours blending. The polygons turn and the wedge opens and closes, all drawn by the GPU. Runs for 20 seconds; three fingers returns.'),
        ('Ring of rectangles', 'psychmetaldemos.finger_ring', 'finger_ring', {},
         'Move one finger and watch a ring of small rectangles follow it and rotate. Runs for 15 seconds.'),
        ('Moving rectangle', 'mouse_rect_demo', 'mouse_rect_demo', {},
         'Move a finger to position a framed rectangle and crosshair. This is the mouse rectangle demo adapted to touch. Runs for 20 seconds.'),
        ('Masked images', 'masked_image_demo', 'masked_image_demo', {},
         'The same colour image appears through original, Gaussian, annulus and raised-cosine apertures. Hold a finger on any panel and drag it. The image and mask remain aligned. Runs for 20 seconds; three fingers returns.'),
        ('Textures', 'texture_demo', 'texture_demo', {},
         'Compare a rotating colour texture, tinted copies of the same image, and a pulsing soft spot that follows your finger. The panels adapt to portrait or landscape. Runs for 20 seconds.'),
    ]),
    ('Contrast and motion', [
        ('Blob array', 'blob_array_demo', 'blob_array_demo', {},
         'Compare soft spots that alternate between light and dark at different rates. Hold one finger on a spot to drag it; lift to leave it. After a brief gray calibration, the labels show frequencies based on the measured refresh rate. Every cycle samples both light and dark peaks. Up to 60 seconds. Contains rapid flicker.'),
        ('Custom GPU spiral', 'shader_demo', 'shader_demo', {},
         'A custom Metal fragment program generates a rotating colour spiral through a Gaussian aperture. The Mac and phone use the same shader source. Runs for 20 seconds; three fingers returns.'),
        ('A pulsing spot', 'blob_demo', 'blob_demo', {},
         'A soft Gaussian spot brightens and darkens once per second. Move a finger to reposition it. Watch its edges blend into the background. Runs for 20 seconds.'),
        ('Drifting stripes', 'gabor_demo', 'gabor_demo', {},
         'Watch stripes move inside soft-edged windows called Gabor patches. Compare their orientations and local motion. Runs for 20 seconds.'),
        ('Moving dots', 'dot_demo', 'dot_demo', {},
         'Watch a field of moving dots. Notice how individual dots combine into a motion pattern. Runs for a short demonstration.'),
    ]),
    ('Noise', [
        ('Changing noise', 'noise_demo', 'noise_demo', dict(cell=1, frames_per_update=1, noise_type='grayscale'),
         'Choose the noise pixel size and the number of display frames per update using the settings above. One frame changes the pattern every refresh; larger values hold the same pattern for that many frames. Tap the noise-type button to choose 1. Binary (black/white), 2. Grayscale, or 3. Colored (independent red/green/blue values). The chosen type stays active for the whole run. Contains rapid changes in brightness. Three fingers returns.'),
        ('Hidden ring', 'hidden_ring_demo', 'hidden_ring_demo', dict(speed=1, cell=1),
         'A ring of noise sits on a different noise pattern in a centered square, invisible while it is still. Move a finger to move it: motion reveals its boundary. Use the settings above to choose how fast the background noise drifts (0 is still; the ring rides along with it) and how large its cells are. Move the ring into the black margins to see it whole. A second finger switches the ring to stripes. Runs for 20 seconds.'),
    ]),
    ('Sound and time', [
        ('Streaming sound', 'audio_stream_demo', 'audio_stream_demo', {},
         'A continuous tone is generated in small blocks and appended to a preallocated audio buffer while playing. Move your finger horizontally to change pitch. Underflow samples count silence inserted when refills arrive late. No microphone is used. Three fingers returns.'),
        ('Movie playback', 'movie_demo', 'movie_demo', {},
         'Play a bundled three-second numbered movie with sound, then draw its frames as a rotating element inside a stimulus. It works offline and does not access Photos. Three fingers returns.'),
        ('Record a stimulus', 'record_demo', 'record_demo', {},
         'Record a drifting Gabor, moving dot and frame counter as an H.264 movie, then replay it. A deliberate pause demonstrates that the movie holds the last frame. The saved movie follows the intended timing even when saving slows the live display. The movie is saved locally in the app and replaced on the next successful recording; it uses generated clicks, not the microphone. Three fingers ends recording early.'),
        ('Export a stimulus', 'export_demo', 'export_demo', {},
         'Create a three-second drifting Gabor movie using the same Metal drawing engine, without opening a stimulus window. The movie uses a 60 Hz frame-counted timeline, independent of this screen. Tap Create movie and wait for Movie ready, then choose Play exported movie or Share movie. It replaces the previous saved movie only after success; no microphone or camera is used.'),
        ('Matching flicker and sound', 'modulation_match_demo', 'modulation_match_demo', {},
         'A soft spot flickers from grey to white; a tone swells and fades. Match one with the other, or two of a kind: turn the dial to match their timing (phase), or slide the knob to match their rate (frequency), then tap Match to see your error. The switches at the top choose what you match and whether each is seen or heard. Flicker rates follow the measured refresh rate, so every cycle shows its brightest and darkest frames. Use the speaker or wired headphones: Bluetooth adds a delay the phone cannot measure. Runs until Quit; three fingers returns. Contains flicker.'),
        ('Sound recorder', 'audio_demo', 'audio_demo', {},
         'A live picture of what the microphone hears, from low pitches at the bottom to high at the top. Hold Record while you speak and lift your finger to stop; Play plays it back. The first time, the app asks to use the microphone. The sound stays on this phone and is discarded when the demonstration ends. Runs until Quit; three fingers returns.'),
    ]),
    ('Optional diagnostics', [
        ('Native timeline', 'timeline_demo', 'timeline_demo', {},
         'A fixed array of Gaussian blobs, replayed inside the native Metal engine. Labels use the measured refresh rate. No dragging. Three fingers returns. Runs for 20 seconds; contains rapid flicker.'),
        ('Frame timing', 'psychmetaldemos.frame_timing', 'frame_timing', {},
         'With Diagnostic mode on, compare frame intervals for a flashing patch and two blob-array conditions. A graph follows. This describes software presentation timing, not a calibrated measurement of emitted light. About 40 seconds; contains rapid flicker.'),
    ]),
]

# Settings chosen on a demo's start page, by title: a label, the argument it
# sets, and the values offered. The catalogue entry's arguments are the defaults.
CHOICES = {
    'Changing noise': [
        ('Noise cell size (pixels)', 'cell', [1, 2, 3, 4, 5]),
        ('Frames per noise update', 'frames_per_update', list(range(1, 61))),
    ],
    'Hidden ring': [
        ('Noise speed (pixels per frame)', 'speed', [0, 1, 2, 3, 4, 5]),
        ('Noise cell size (pixels)', 'cell', [1, 2, 3, 4, 5]),
    ],
}
