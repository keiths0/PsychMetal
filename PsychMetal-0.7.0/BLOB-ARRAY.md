# Draggable counterphasing blobs

MATLAB/Octave, after adding this version's folder to your path:

```matlab
PsychMetalBlobArrayDemo;          % 60 seconds, full black/white excursion
PsychMetalBlobArrayDemo(120, .25); % 120 seconds, smaller excursion
```

Python, in an environment with psychmetal 0.7.0 and numpy, from this folder:

```bash
python python/blob_array_demo.py
python python/blob_array_demo.py 120 .25
```

On iPhone/iPad, rebuild/update the [phone app](phone/README.md), then select
**Blob array**. Press a blob with one finger, drag, and lift to leave it.
On Mac hold the left mouse button to drag; releasing stops movement. A blob
retains the point at which you grabbed it, comes to the front, and can overlap
other blobs. Labels follow their blobs. Escape (or three fingers) ends the demo.

At 60 Hz the labelled frequencies are 30, 15, 7.5, 3.75, 1.875 and 0.9375 Hz.
At 120 Hz there is also a 60 Hz blob. The last frequency is the octave closest
to 1 Hz. Each Gaussian is evaluated on the GPU, without texture uploads.
The layout adapts to the screen's size and orientation when opened.

The cosine waveform starts at its positive peak, so the highest frequency
alternates white and black every frame. Frequencies assume one frame per
refresh; missed refreshes slow the sequence. The function returns frame
statistics and final positions. This is a demonstration, not a measurement
of physical flicker frequency. Display gamma and pixel response affect the
light emitted; no gamma correction is enabled by this demo.

With the default contrast of 0.5 an isolated blob's centre spans black to white
on mid-grey. Overlapping Gaussians use ordinary alpha compositing, so their
values in the overlap are affected by the blobs underneath. Circular hit areas
include the faint outer part of each Gaussian.

Automated tests exercise frequency selection, the Nyquist waveform, layout,
mouse/finger dragging, cancellation and multiple-finger handling. Visual and
touch acceptance on hardware is still required.
