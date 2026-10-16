# PsychMetal 0.9.0 development audit — 2026-10-11

This audit covers the changes from 0.8.1, concentrating on the new shared audio
core, host session, Core Audio/RemoteIO backend, front ends and demos. This is
not release approval or a claim of measured audiovisual onset accuracy.

## Fixed in this pass

- **Recording restart/read race:** a queued restart could leave the old sample
  count visible while capture overwrote that memory. The recorder now publishes
  the applied recording id; the host returns an empty new recording until its
  reset is acknowledged. Published samples are subsequently append-only during
  a host read. The first-sample timestamp is published with the sample prefix.
  An older recording's End event cannot mark the replacement as finished.
- **Python shutdown:** destruction of the audio session now takes the same
  bounded audio lock as other Python audio calls, after the existing graphics
  and input locks. A concurrent audio operation cannot use the freed session.
- **Unaligned sound arrays:** sample loads use memcpy, supporting legal NumPy
  views with reversed strides and unaligned storage. Finite doubles that would
  overflow float storage are rejected instead of introducing infinities.
- **Callback workload:** input and output process at most one ring's capacity
  of commands per callback. A continuously replenishing producer can no longer
  keep either callback in its command-draining loop indefinitely.
- **Event order:** input and output event rings are merged by sample timestamp.
  Untimed events follow timed events and retain their arrival order.
- **Resource lifetime:** failed command submission releases the host's orphaned
  voice reference; sample-rate converters use exception-safe ownership; iOS
  notification blocks retain a shared flag rather than a raw Audio pointer.
- **Clock initialization:** the immutable host-tick conversion is initialized
  before callbacks start, eliminating concurrent lazy writes from input/output.
- **Route status:** a detected interruption/device change clears `timed` until
  the session is reopened; old rate/latency metadata is no longer labelled timed.
- **Spectrogram:** the window, normalization and frequency grids are cached
  between columns. Pixel equivalence is tested against the original calculation.
- **Documentation:** README now identifies implemented audio and links AUDIO.md;
  restart and route-status behavior are documented there.

## Findings from this audit, resolved after it

1. **Mac device changes and settings ownership — fixed.** The device is watched
   for its sample rate and buffer size as well as for going away; a change this
   session did not make invalidates timing and raises the route warning. Opening
   records the rate and buffer size it found; closing (and a failed open) puts
   them back only where the device still has this session's setting. Type-checked
   against the SDK stubs; not yet run against a device whose settings change.
2. **Overflow-safe voice retirement — fixed.** Every voice that ends, however it
   ends, is reported on its own retirement ring, apart from the user-facing
   events, and the host releases sounds on retirements. The host keeps at most
   that ring's capacity (2048) of voices outstanding, so it cannot fill. Tested:
   3000 one-sample sounds in bursts past the mixer's voices and the event ring,
   without polling between buffers, retire every voice and release the sound.
3. **Handles across close/reopen — fixed.** Sound, voice, recording and key ids
   come from process-wide counters. Tested: an old sound handle is refused after
   reopening, an old voice is treated as ended, and new ids never repeat old ones.

## Known limits of 0.9.0

4. **Audio timing measurements.** Output and input callback timestamps and
   latency conventions are as Core Audio and the audio session report them. They
   have not been validated with a loopback cable or a photodiode and microphone,
   including separate input and output devices and rates.
5. **Interruption policy.** After an interruption or a route change, audio warns
   and reports `timed=false` until it is closed and reopened; voices are not given
   an `Interrupted` end. PsychMetal does not restart audio itself; whether sound
   resumes is up to the system (after Siri on an iPhone it resumed). On an
   iPhone, Siri silenced the app's sound and iOS posted no interruption notice,
   so nothing was reported; a phone call has not yet been tried. The mixer now
   also watches its own callbacks: one that starts more than 50 ms after the
   previous buffer ended means the output stopped, and is reported the same way
   whether or not the system said anything. Whether Siri stops the output (and
   so is now caught) or only silences it is to be confirmed on the iPhone. A
   complete policy the same on Mac and iOS is deferred.

## Validation and packaging

- Native Apple Silicon MATLAB, Octave and Python extensions rebuilt successfully.
- Engine type checks cover macOS, iOS device and iOS simulator with real SDKs.
- Regression coverage includes wrapper/frontend parity, scripted phone flows,
  audio sample timing and command rings. New audio-host tests run under both
  Address/UndefinedBehavior sanitizers and ThreadSanitizer, including concurrent
  restart/copy, unaligned reversed arrays, float overflow and input/output order.
- GPU pixel tests explicitly skip here because no Metal device is accessible.
  Actual audio routes, microphone permission prompts, interruption recovery and
  audiovisual onset accuracy require physical devices.
- The Mac binaries and both iOS wheels were rebuilt after these fixes; the app
  built from them awaits the sound checks in phone/READY-TO-TEST.md.
- `tests/make_release_manifest.py` writes RELEASE-MANIFEST.txt and SHA256SUMS
  from the folder, and refuses a binary older than its sources. Run it once
  more after the final validation edits.
