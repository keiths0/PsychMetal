# PsychMetal 0.11.0 phone validation — October 17, 2026

The app was rebuilt from 0.11.0 device and simulator wheels and run on Keith's
iPhone. The record demo paused on its first click and resumed where it stopped;
Siri during a sound demo stopped it with the interruption message. See
../../VALIDATION.md. No App Store upload has been performed.

---

# PsychMetal 0.10.1 phone validation — October 16, 2026

Keith confirmed the new phone checks work. Current app and noise/menu sources
were rebuilt and passed offline bundle/privacy checks: 0.10.1 build 1,
88 compatible frameworks. No App Store upload has been performed.
See ../../VALIDATION.md for evidence and limits. Individual device/orientation,
route/permission and timing scenarios were not separately logged.

Historical evidence below belongs to the version named, not 0.10.1.

---

# PsychMetal 0.9.0 validation — local acceptance, October 12, 2026

Final rebuilt Mac binaries passed the checks recorded below, and Keith reported
that the iPhone tests work. These are functional acceptance results, not
physical timing certification. Remote Linux/macOS CI and all five Mac wheel builds passed for source commit
90d6417; links below.

## Completed checks (automated, against the current 0.9.0 sources)

- Real macOS, iOS device and ARM64 simulator SDK type checks of the engine,
  audio included, passed with -Wall -Wextra -Wpedantic.
- Full regression runner passed, including both host bindings against the
  scripted engine. Octave inventory: **249/249 checks across 92 commands**;
  readback: **46/46**. Python front end, demos, phone menu/report tests, custom
  shader validation, cancellation and adaptive wait tests passed.
- Audio core under AddressSanitizer/UndefinedBehaviorSanitizer and
  ThreadSanitizer: sample-exact starts and stops across buffers of any size,
  late starts, repeats, mixing, clipping, capacity, clock-rate drift; recording,
  voice key and the input monitor read while written; amplitude modulation on
  GetSecs time with timed changes on the exact sample. A flat-out writer against
  the largest monitor read refused overwritten reads and returned no wrong
  samples. The audio host under both sanitizers: a recording restarted while
  being copied, unaligned and reversed-stride sounds, float overflow rejected,
  and input and output events merged in time order (AUDIT-0.9.0.md in the 0.9.0 release). Voices
  retired and sounds released through a burst past the mixer's voices and the
  event ring; handles across close and reopen never alias.
- Through the scripted 48 kHz loopback device, from Python and through MEX:
  scheduled and frame-keyed sounds, modulation read back sample for sample
  within 1e-5, recording on exact samples, the voice key's time and frame, a
  refused microphone (PsychMetal:Microphone), Bluetooth refusal and the route
  warning.
- Both sound demos by scripted mouse and keys (Python, Octave) and by scripted
  finger on a portrait phone screen; the matching demo's frequencies have an even
  number of frames per cycle at every refresh rate tested, with peak and trough
  on frames, and its blob and tone follow the same function of time.
- Phone packaging: the menu lists every non-keyboard demo; help, privacy policy
  and support site pages agree; the bundle check requires the microphone usage
  text.

## On hardware so far (by eye and ear, not measurement)

- Mac: built against the real SDK after a naming clash with the SDK's `struct
  session` was fixed; the spectrogram demo recorded and played back.
- Mac Studio Speakers, from Python: opening at 48000 Hz moved the device from
  44100 to 48000 and closing put 44100 back. With audio open, a change to
  96000 Hz in Audio MIDI Setup gave the route warning and `timed` false at the
  next call, and closing left 96000 in place. (The first run found that every
  new rate failed: the device switches after the request returns. Fixed.)
- iPhone: device and simulator wheels built; the app built and ran. The matching
  demo's tones played from the speaker. Recorder playback went to the earpiece;
  the fix (moving output from the receiver to the speaker) is in these sources.
  The Mac binaries and both wheels were rebuilt from the final sources, and the
  app built from them; its sound checks are below.

## Final physical acceptance — October 12, 2026

- Mac Octave inventory repeat: **249/249 across 92 commands**. The first run
  passed 248/249: relative WaitSecs median overshoot was 667.9 microseconds
  against a 600 microsecond tolerance (worst 918.7). Both absolute and relative
  waits passed on repeat; retain the first result as evidence of intermittent
  scheduling variability, not a guarantee of future wait precision.
- GPU polygon and custom-shader tests passed on Keith's Mac. Hardware handle/
  snapshot test completed; readback passed **46/46**; startup **10/10** passed.
- Motion tests at 1024 and 2048: each **600/600 confirmed**, **60.000 Hz**, zero
  long adjacent intervals and zero missing measured timestamps. Median uploads
  were 1.519 and 6.157 ms respectively.
- Python sound demos completed without exceptions. Octave recorder returned a
  1.2333-second recording with record/play/stop actions and microphone access;
  the matching demo returned a completed phase trial. This is not MATLAB testing.
- Keith reported that the iPhone tests work. The supplied console shows no
  Python exception or Metal assertion. It does show a debugger attached, so
  this log cannot certify undisturbed frame timing. Individual route and
  permission scenarios were not separately logged.
- Offline device and simulator builds passed bundle and privacy checks, with
  88 compatible frameworks each. The device bundle contains Assets.car and
  configured iPhone/iPad AppIcon files despite the runtime fallback-icon warning.

## Release verification

- [Linux/macOS CI](https://github.com/keiths0/PsychMetal/actions/runs/38310222083) passed for source commit 90d6417.
- [Python 3.10–3.14 Mac wheels and source distribution](https://github.com/keiths0/PsychMetal/actions/runs/38310243097) passed.
  Subsequent release-record edits do not change native or Python package sources.
- Publication metadata is dated October 12; regenerate manifest/checksums
  after any further release edits.
- Broader hardware coverage below remains outside this acceptance run.

## Limits

Audio times are those Core Audio and the iOS audio session report. They have not
been measured with a microphone, a photodiode or a loopback cable; a
loudspeaker, a display's own processing and a device that misreports its
latency add delay no software sees. The same holds for presentation timestamps:
GPU pixels and reported times do not prove emitted-light timing. Photodiode and
microphone measurement is required for those claims.

This execution environment has no accessible Metal GPU, audio device or active
display; Metal pixel fixtures compile but skip execution here. Unsigned builds
and offline privacy checks are not a signed App Store archive or Apple's
server-side validation. The broader hardware matrix includes MATLAB/Octave/Python
on the same Mac, 60 Hz and high-refresh displays, HiDPI and multiple monitors,
iPhone/iPad in both orientations, and background/resume. The supplied Octave
binary uses Octave 11.3 libraries requiring macOS 26; MATLAB/Python target
macOS 14+. Video is deferred to 0.10.1. GitHub release and Apple submission are
separate.
