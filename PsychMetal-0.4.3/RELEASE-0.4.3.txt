# PsychMetal 0.4.3 — 2026-09-17

Native Metal stimulus presentation for Apple Silicon, with Octave and MATLAB binaries and source. This release includes the 0.4.1 demo/signature corrections and the 0.4.2 mouse and background keyboard queue fixes; their changelog entries are retained.

## Changes

- OpenWindow confirms two consecutive presentations of the requested background before returning. Initialization has bounded confirmation attempts, cleans up on failure, and records startup history separately from stimulus frames.
- Preserve the first scheduled deadline before refresh-grid calibration; retain the existing default pacing policy.
- Add UpdateTexture and direct native image packing for uint8, single, double and logical arrays. Grayscale uses a single-channel texture; large images use tiled packing. Reusable texture storage is protected until GPU completion.
- Fix OpenWindow option indexing, resolution dispatch, native input validation, draw-list overflow handling and a DrawTexture error-path deadlock.
- Retain queued texture snapshots, use unique handles, fence shared drawing buffers and reject callbacks from earlier sessions. Fix close-after-prepare and reopen behavior.
- Consolidate Flip into one native call, report submission/GPU/confirmation failures explicitly, and separate drawable, encoding and prefetch measurements.
- Keep canonical Metal shader source separate and correct output-alpha blending.
- Make keyboard waits interruptible, add KbQueueStatus, define queue Flush as a scan barrier, and avoid owner-PID lookup in KbCheck's Secure Input check.
- Improve inventory and native regression checks; include motion and repeated-open acceptance tests. Optional Psychtoolbox comparisons live in comparisons/.

## Compatibility and validation

Finite floating-point texture inputs use 0–1; uint8 inputs use 0–255. Noise rectangles require integers. Geometry diagnostic fields were renamed and handles are opaque and not recycled. Restart Octave/MATLAB to switch native builds after opening a graphics window: the MEX remains pinned to protect asynchronous callbacks.

On the tested 6016×3384, 60 Hz display in Octave, the final binary passed 10/10 repeated-open/first-stimulus checks and all 151 inventory checks across 49 public commands. Startup confirmation took 3–5 attempts (88–115 ms); whole OpenWindow calls took about 1.38–1.47 s. Earlier optimization-stage throughput tests are recorded separately in VALIDATION.md.

The MATLAB binary was built but has not received equivalent hardware testing. Timing is based on Metal presentation reports; no photodiode validation or universal frame-rate guarantee is claimed. The supplied Octave binary links Homebrew Octave 11.3.0; rebuild for a different installation if required.
