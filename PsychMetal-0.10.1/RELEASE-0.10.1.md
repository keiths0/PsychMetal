# PsychMetal 0.10.1

Relative-linear HDR/EDR presentation, reusable GPU imaging pipelines and online
PCM refilling share the native engine across Python, MATLAB/Octave and iOS.
HDR includes floating texture uploads/readback, dynamic headroom and exposure.
Imaging provides Gaussian blur, color matrices, exposure, convolution and inverse
affine resampling. Streams use preallocated bounded buffers with refill,
end-of-stream and underflow reporting. An offline recording stop/append race
was fixed with a deterministic regression.

The Mac/phone demos include a circular HDR pairwise flicker grid with adjustable
whole-frame cadence, image processing and interactive streaming sound. Phone
menus have clearer artwork/categories; Changing noise adds cell size, frames
per update and Binary / Grayscale / Colored selection. Noise remains GPU-generated.

## Compatibility and downloads

The release ZIP includes source, docs, demos, tests, MATLAB/Octave binaries,
the local Python 3.15 Mac extension and Python 3.14 iOS device/simulator wheels.
A Python 3.14 ARM64 Mac wheel and source archive are prepared separately.
MATLAB/Python require Apple silicon/macOS 14+; the supplied Octave 11.3 binary
requires macOS 26+. Toolbox iOS wheels require 15+; the phone app requires 17+.
Add only this version folder to the MATLAB/Octave path.

## Validation and scope

Final available software regressions passed (295 inventory, 46 readback,
memory/undefined-behavior/thread sanitizers), with explicit GPU/codec skips in
this execution environment. Keith's Mac checks passed: readback 46/46, actual Metal imaging pixels,
600/600 frames at both 1024 and 2048 with no long intervals, 50/50 opens, and
streaming with zero underflows. Keith also confirmed the Mac/phone demo checks
work. See VALIDATION.md for software results and limits; reported times do not
certify physical light/sound onset. HDR is relative-linear EDR, not calibrated
nits or HDR movie encoding/decoding. Broader device/codec coverage remains open.

GitHub publication, PyPI upload and App Store submission are separate actions.
This GitHub release does not upload to PyPI or the App Store.
