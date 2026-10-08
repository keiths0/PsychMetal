"""What the app can run: (title, module, function, arguments, a line about it).

The first two groups are the psychmetal package's own files, from its python
folder. Blob array uses direct one-finger dragging. The older demos were written
for a mouse and a keyboard, which on a phone are fingers: one finger is the
pointer, a second finger is the click, a third is Escape.
"""
GROUPS = [
    ('Demos', [
        ('One rectangle', 'minimal_demo', 'minimal_demo', {}, 'Three seconds.'),
        ('Dynamic noise', 'noise_demo', 'noise_demo', {}, 'New noise every frame. Two fingers stop it.'),
        ('Drifting Gabors', 'gabor_demo', 'gabor_demo', {}, 'Two fingers stop it.'),
        ('Textures', 'texture_demo', 'texture_demo', {}, 'Two fingers stop it.'),
        ('Dot motion', 'dot_demo', 'dot_demo', {}, 'Two fingers stop it.'),
        ('Blob array', 'blob_array_demo', 'blob_array_demo', {},
         'Hold one finger on a blob to drag; lift to leave it. Sixty seconds, or three fingers.'),
        ('Blob', 'blob_demo', 'blob_demo', {}, 'It follows a finger. Two fingers stop it.'),
        ('Rectangle', 'mouse_rect_demo', 'mouse_rect_demo', {}, 'It follows a finger. Two fingers stop it.'),
        ('Noise through a mask', 'stimulus_demo', 'stimulus_demo', {},
         'Noise, and a grating in a patch that follows a finger. Two fingers stop it. Made for a screen held sideways.'),
        ('Pointer and buttons', 'mouse_test', 'mouse_test', {}, 'Thirty seconds, or three fingers.'),
        ('Keyboard', 'kb_demo', 'kb_demo', {}, 'Needs a keyboard. Two fingers stop it.'),
        ('Keyboard queue', 'kb_queue_demo', 'kb_queue_demo', {}, 'Needs a keyboard. Fifteen seconds.'),
    ]),
    ('Tests', [
        ('Readback test', 'readback_test', 'readback_test', {},
         'What the GPU draws, pixel for pixel. About six seconds. Its 10-bit checks fail here: a phone\'s window '
         'is 8-bit.'),
        ('Inventory test', 'inventory_test', 'inventory_test', {},
         'Every command. Written for a Mac: what a phone does not have will fail.'),
        ('Hardware test', 'hardware_test', 'hardware_test', {}, 'Three panels, then blue. Four seconds.'),
        ('Display test', 'display_test', 'display_test', {}, 'Needs a keyboard to answer its questions.'),
        ('Gamma by eye', 'gamma_calibration', 'gamma_calibration', {}, 'Needs a keyboard.'),
    ]),
    ('Made for fingers', [
        ('Ring of rectangles', 'psychmetaldemos.finger_ring', 'finger_ring', {},
         'It turns round a finger. Fifteen seconds, or three fingers.'),
        ('Still noise, 1 pixel', 'psychmetaldemos.noise_annulus', 'noise_annulus', dict(scroll=0, grain=1),
         'A finger moves the ring; a second changes it to a grating. Three fingers end it.'),
        ('Still noise, 3 pixels', 'psychmetaldemos.noise_annulus', 'noise_annulus', dict(scroll=0, grain=3), ''),
        ('Scrolling noise, 1 pixel', 'psychmetaldemos.noise_annulus', 'noise_annulus', dict(scroll=1, grain=1),
         'The background and the ring move a pixel a frame.'),
        ('Scrolling noise, 3 pixels', 'psychmetaldemos.noise_annulus', 'noise_annulus', dict(scroll=1, grain=3),
         ''),
        ('Check the ring', 'psychmetaldemos.ring_check', 'ring_check', {},
         'Reads the ring and the noise back, pixel by pixel. A second.'),
    ]),
]
