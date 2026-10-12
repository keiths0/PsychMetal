# Scheduled audio for PsychMetal: design, version 1

October 10, 2026. For the next major version (0.9.0). Nothing here is built yet.

## Aim

Play preloaded sounds with sample-accurate starts, at a GetSecs time or at the
moment a queued frame is presented, on Apple silicon Macs and on iPhone/iPad.
Report for every sound when it actually started, in the same clock as Flip,
including the output latency, and say plainly when that number cannot be
trusted (Bluetooth, AirPlay, a changed route).

Written from Apple's interfaces, not from PsychPortAudio. Call names follow
PsychMetal's conventions; where PsychPortAudio's shape was already right
(load a buffer once, start it at a time, get the onset back) the calls do the
same thing, so porting a script is a matter of renaming, not redesigning.

## What makes it better than a port

1. **One clock for sound and light.** Core Audio stamps every output buffer
   with a host time in the same mach ticks as `CACurrentMediaTime`, Metal's
   presentation times and GetSecs. No conversion, no drift estimate between
   two clocks.
2. **Sound keyed to a frame.** `play(sound, frame=token)` starts the sound at
   the projected presentation time of a frame already queued with
   `queue_flip`/`prepare_flip`, and the results then give both the sound's
   onset and the frame's confirmed presentation time. A script never computes
   `vbl + offset` itself.
3. **Sample-accurate start.** The render callback converts the requested
   onset into a sample index inside the buffer it is filling and starts the
   sound on that sample: a resolution of 1/48000 s, not one buffer.
4. **Honest latency.** The reported onset includes the device's own latency
   and stream latency as Core Audio reports them, and every result carries the
   route it was played on. Bluetooth and AirPlay are refused for timed playback
   by default, because their latency is long and varies from moment to moment.
5. **No mixing devices.** Every `play` is a voice. The callback mixes any
   number of voices; there are no "slave" devices to open.

## Interface

Python first; MATLAB/Octave the same commands with PsychMetal's usual names
and one-based indices. One audio output per process, as one window.

| Python | MATLAB/Octave | Does |
|---|---|---|
| `info = pm.open_audio(device=None, rate=None, channels=2, buffer_frames=None, routes='wired')` | `info = PsychMetal('OpenAudio', options)` | Opens the output. Returns rate, channels, buffer frames, output latency (s), device and route names, transport type. |
| `pm.audio_devices()` | `PsychMetal('AudioDevices')` | Mac: output devices with rates, transport, latency. Phone: the current route. |
| `s = pm.make_sound(samples, rate=None)` | `s = PsychMetal('MakeSound', samples, rate)` | Copies samples (n, or n x channels; float or int16) into a preloaded, device-rate float buffer. Mono plays on all channels. A different `rate` is converted once, here, with Core Audio's high-quality converter, never in the callback. |
| `v = pm.play(s, when=None, frame=None, offset=0, gain=1, repeats=1)` | `v = PsychMetal('Play', s, when, frame, offset, gain, repeats)` | Schedules a voice and returns its id at once. `when` is a GetSecs time; `frame` a queued frame's token, with `offset` seconds after it. Neither: as soon as possible. |
| `pm.stop_sound(v=None, when=None)` | `PsychMetal('StopSound', v, when)` | Stops one voice, or all, now or at a time, on a sample. |
| `rows = pm.sound_results(wait=False)` | `PsychMetal('SoundResults', wait)` | One row per finished or started voice, reported once: `[voice, sound, requested onset, actual onset, end, status, frame token, frame presented]`. Status: played, late (started after its time), stopped, refused (route), dropped (device lost). |
| `pm.close_sound(s)`, `pm.close_audio()` | `CloseSound`, `CloseAudio` | Playing voices keep their sound until they end. |

Helpers in Python and MATLAB, not the engine: `tone(freq, seconds, rate, ramp)`,
`click(seconds, rate)`, `noise(seconds, rate, seed)`, and reading a WAV/AIFF
file (Core Audio's file reader, so no extra dependency).

## Engine design

- **Output unit.** One AudioUnit: `HALOutput` on the Mac, `RemoteIO` on
  iOS. Same render callback, same float32 non-interleaved format at the
  device's rate. On the Mac the device's buffer frame size is set small
  (default 64 frames, 1.3 ms at 48 kHz; configurable down to the device's
  minimum); on iOS the audio session asks for the same with
  `preferredIOBufferDuration` and the result reports what iOS granted.
- **iOS audio session.** Category playback, so the silent switch does not mute
  an experiment; no mixing with other apps. Interruptions (a call, Siri) and
  route changes (headphones unplugged) end scheduled voices with a status
  saying why, the same way leaving the app ends a run.
- **Sample rate.** The device's rate is used as it is unless `rate` is given.
  On the Mac a requested rate sets the device's nominal rate and is reported;
  on iOS it is a preference and the granted rate is reported. Nothing is
  resampled in the callback.
- **Scheduling arithmetic.** Each callback receives the buffer's sample time
  and host time. A voice due at onset T starts at sample
  `(T - latency - bufferHostTime) * rate * rateScalar` into the buffer, rounded
  to the nearest sample; one already past its time starts on the first sample
  and is reported late with its real onset. This arithmetic lives in a
  header with no Apple dependency (as the timeline core does), so it is tested
  on any machine with simulated callback timestamps, including rate scalars
  and clock jumps.
- **Real-time safety.** The callback takes no locks, allocates nothing and
  frees nothing. Commands arrive through a single-producer/single-consumer
  lock-free ring; results leave through another; sounds a voice has finished
  with go back to a non-real-time thread to be released. ThreadSanitizer tests
  run the rings with a simulated callback thread.
- **Mixing.** Voices are summed in float with their gain. Samples beyond ±1
  are clipped and counted, and the count is reported, never silently limited.
- **Frame-keyed starts.** For `frame=token`, the engine reads the frame's
  projected presentation time from the queue at the moment `play` is called
  and schedules the voice for it. The sound cannot follow a frame that later
  presents late (the audio is already committed by then); the result shows
  both times so the difference is visible, and the docs say so.
- **Route policy.** Transport type from Core Audio (Mac) or the session's
  current route (iOS). Built-in, wired, USB and HDMI/DisplayPort are timed
  routes. Bluetooth and AirPlay are refused for scheduled playback unless
  `routes='any'`, and then every result is marked untimed. A route change
  during a session is reported in the results and the environment report.
- **Environment report.** Device, route, rate, buffer frames, reported
  latencies (device, stream, safety offset), and system output volume where
  readable. The engine cannot set the iPhone's volume and does not try.

## What it cannot claim

The reported onset is when Core Audio says the first sample reaches the
device's output, plus the latency the device reports. It is not the acoustic
onset at the ear: a speaker, headphone or amplifier adds its own delay, and
some devices report their latency wrongly. Like Flip's timestamps, these are
software times. The release ships a measurement tool, and no audio timing
claim is made until it has been run:

- **Sync check.** A click and a white photodiode patch scheduled for the same
  frame, repeated. Microphone or audio line and photodiode go into a
  two-channel scope or a recorder; the tool prints what to measure. This needs
  the photodiode patch from the wish list, so that comes in the same release.
- **Loopback check (Mac with an audio interface).** Output wired to input;
  PsychMetal records its own clicks and reports scheduled-to-recorded offsets
  and their spread. This needs audio input, which is otherwise out of scope
  for the first version.

## Out of scope for the first version

Recording and voice keys (the design leaves room: same unit, input bus), more
than one output device at a time, multichannel layouts beyond plain channel
counts, streaming sounds longer than memory, and audio effects. Sound
generation beyond the helpers is the script's job.

## Tests

- Scheduling header: onsets mid-buffer, at buffer edges, late, repeats, stop
  times, rate scalars, host-time jumps; bit-exact sample positions.
- Rings and lifetimes under ThreadSanitizer, with sounds closed while voices
  play.
- Scripted engine for both front ends: every command, argument errors,
  results rows, frame-keyed scheduling against the scripted frame queue.
- The real render callback, called directly with synthetic timestamps and no
  device, its output compared sample for sample with what was scheduled.
- Mac hardware: open/close cycles, device listing and route refusal.
- Phone: interruption and route-change handling by hand; timing only with the
  sync check.

## Order of work

1. Scheduling header and its tests.
2. Mac output unit, rings, mixing, results; Python binding; offline-render test.
3. MATLAB/Octave commands and the scripted engine.
4. iOS session and RemoteIO; phone demo (a click train with a flash).
5. Photodiode patch; sync check tool; documentation with measured numbers.
