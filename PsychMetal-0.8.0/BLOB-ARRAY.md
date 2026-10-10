# Draggable counterphasing blobs

MATLAB/Octave, after adding this version's folder to your path:

```matlab
PsychMetalBlobArrayDemo;          % 60 seconds, full black/white excursion
PsychMetalBlobArrayDemo(120, .25); % 120 seconds, smaller excursion
```

Python, in an environment with psychmetal 0.7.2 and numpy, from this folder:

```bash
python python/blob_array_demo.py
python python/blob_array_demo.py 120 .25
```

On iPhone/iPad, rebuild/update the [phone app](phone/README.md), then select
**Blob array**. Press a blob with one finger, drag, and lift to leave it.
On Mac hold the left mouse button to drag; releasing stops movement. A blob
retains the point at which you grabbed it, comes to the front, and can overlap
other blobs. Labels follow their blobs. Escape (or three fingers) ends the demo.

At a measured 60 Hz the labelled frequencies are approximately 30, 15, 10,
7.5, 3.75, 1.875 and 0.9375 Hz. At a measured 120 Hz they are approximately
60, 30, 20, 15, 7.5, 3.75, 1.875 and 0.9375 Hz. Labels use the actual measured
refresh interval rather than a nominal 60/120 assumption. Every period has an
even integer number of frames and includes both the positive and negative
cosine peaks, with uniformly spaced phases indexed by frame count. Each
Gaussian is evaluated on the GPU, without texture uploads.
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
mouse/finger dragging, cancellation and multiple-finger handling. The user accepted the current phone visuals and touch interaction; this is not
physical-light calibration or exhaustive acceptance across devices.
