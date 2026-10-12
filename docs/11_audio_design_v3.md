# Scheduled audio for PsychMetal: design, version 3

October 11, 2026. For 0.9.0. Version 3 adds input: recording and a voice key,
built now, and opened only when a script asks for it, so playback is unchanged.

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
| `info = pm.open_audio(device=None, rate=None, channels=2, buffer_frames=None, routes='wired', input=False, input_device=None, input_channels=1, record_seconds=60)` | `info = PsychMetal('OpenAudio', options)` | Opens the output, and with `input=True` the input too, with memory for `record_seconds` allocated here. Returns rate, channels, buffer frames, output and input latency (s), device and route names, transport types. |
| `pm.audio_devices()` | `PsychMetal('AudioDevices')` | Mac: output and input devices with rates, transport, latency. Phone: the current route. |
| `s = pm.make_sound(samples, rate=None)` | `s = PsychMetal('MakeSound', samples, rate)` | Copies samples (n, or n x channels; float or int16) into a preloaded, device-rate float buffer. Mono plays on all channels. A different `rate` is converted once, here, with Core Audio's high-quality converter, never in the callback. |
| `v = pm.play(s, when=None, frame=None, offset=0, gain=1, repeats=1)` | `v = PsychMetal('Play', s, when, frame, offset, gain, repeats)` | Schedules a voice and returns its id at once. `when` is a GetSecs time; `frame` a queued frame's token, with `offset` seconds after it. Neither: as soon as possible. |
| `pm.stop_sound(v=None, when=None)` | `PsychMetal('StopSound', v, when)` | Stops one voice, or all, now or at a time, on a sample. |
| `r = pm.start_recording(when=None)`, `pm.stop_recording(when=None)` | `StartRecording`, `StopRecording` | One recording at a time, starting and stopping on the sample nearest each time. A new recording replaces the last one's samples. |
| `samples, t0 = pm.get_recording()` | `[samples, t0] = PsychMetal('GetRecording')` | A copy of the recording so far (frames x channels) and the time of its first sample. Works while it is still recording. |
| `k = pm.voice_key(threshold, when=None, window=0.001, minimum=1)` | `PsychMetal('VoiceKey', threshold, when, window, minimum)` | Arms a one-shot key from `when`: it triggers when `minimum` samples within `window` seconds reach `threshold` (absolute amplitude, 0–1), and reports the first of them. `minimum` above 1 ignores single clicks. |
| `rows = pm.audio_results(wait=0)` | `PsychMetal('AudioResults', wait)` | Events, each reported once, waiting up to `wait` seconds for the first: `[kind, id, requested time, actual time, status, frames, level, frame token, frame presented]`. Kinds: sound start, sound end, recording start, recording end, key. Status: on time, late, finished, stopped, full (recording memory), refused, dropped (device lost). For a key during a recording, `frames` is its frame in the recording. |
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
  and their spread. It uses the new audio input.

## Input: recording and voice key, without costing playback

- **Opened only when asked.** `open_audio(input=False)` is the default and opens
  no input at all: no microphone permission, and on iOS the session stays
  category playback, so output latency and routing are exactly as without
  input. `input=True` opens a second unit for input; on iOS it switches the
  session to play-and-record with output kept on the speaker, not the earpiece,
  and that may change the buffer iOS grants (reported, as always).
- **Its own thread and clock.** On the Mac, built-in input and output are
  separate devices with separate clocks and separate callbacks. Each input
  buffer is stamped with its host time less the input latency, with the same
  arithmetic playback uses, so recording onsets, voice-key times, sound onsets
  and frame times are all in one clock. No aggregate device is needed.
- **Real-time safe like playback.** Memory for `record_seconds` is allocated
  when input opens; the capture callback copies into it and publishes how far
  it has got, so `get_recording` can read a recording while it grows. The
  voice key tests every sample as it arrives and keeps a window of at most a
  third of a second; it never waits for a buffer to fill.
- **What it cannot claim.** A key's time is when the sound reached the input,
  by Core Audio's account of the input latency, not when the person began to
  speak: the microphone, its distance and the amplitude threshold all shift it.
  Thresholds are relative to the input's level, which the operating system's
  input gain sets. The loopback check measures the input latency against the
  output's.
- **Permissions.** Mac: the first input asks for microphone access for the
  program running Python, MATLAB or Octave; refusal is an error at
  `open_audio`, not silent zeros. iOS: the app needs a microphone usage string
  and asks once. The demo app does not record, but the engine it bundles can, so
  it carries the usage string to satisfy App Store scanning; its privacy answers
  stay "no data collected", because nothing recorded leaves the device.

## Out of scope for the first version

More than one output or input device at a time, multichannel layouts beyond plain channel
counts, streaming sounds longer than memory, and audio effects. Sound
generation beyond the helpers is the script's job.

## Tests

- Scheduling header: onsets mid-buffer, at buffer edges, late, repeats, stop
  times, rate scalars, host-time jumps; bit-exact sample positions.
- Rings and lifetimes under ThreadSanitizer, with sounds closed while voices
  play.
- Recorder and voice key: exact start and stop samples, full memory, late
  starts, windows that reject single clicks, triggers across buffer edges, the
  key's frame within a recording, and reading a recording while it is written
  (ThreadSanitizer).
- Scripted engine for both front ends: every command, argument errors,
  results rows, frame-keyed scheduling against the scripted frame queue.
- The real render callback, called directly with synthetic timestamps and no
  device, its output compared sample for sample with what was scheduled.
- Mac hardware: open/close cycles, device listing and route refusal.
- Phone: interruption and route-change handling by hand; timing only with the
  sync check.

## Order of work

1. Scheduling header, recorder and voice key, and their tests. (Done.)
2. Mac output and input units, results; Python binding; direct-callback tests.
3. MATLAB/Octave commands and the scripted engine.
4. iOS session and RemoteIO; phone demo (a click train with a flash).
5. Photodiode patch; sync and loopback checks; documentation with measured numbers.
