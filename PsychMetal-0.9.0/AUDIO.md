# Audio: scheduled sounds, recording and a voice key

PsychMetal plays preloaded sounds that start on the sample nearest a requested
time, records from the input on exact samples, and arms a voice key, all in
GetSecs time, the clock of Flip. It runs on Apple silicon Macs through Core
Audio and on iPhone/iPad through the audio session. Python, MATLAB and Octave
have the same commands.

Status (0.9.0 development): the scheduling core, host session and both front
ends are tested sample for sample against a simulated device. Core Audio
playback, recording and the latencies it reports have not yet been measured on
hardware; until the sync check below has been run, treat reported times as
software times, as for Flip.

## Python

```python
import psychmetal as pm

info = pm.open_audio()                    # the system's output; info['rate'], info['outputLatency']
beep = pm.make_sound(pm.tone(1000, 0.05, info['rate']))
voice = pm.play(beep, when=pm.get_secs() + 0.5)
events = pm.audio_results(wait=1)         # [{'kind': 'sound start', 'time': ..., 'status': 'on time'}, ...]
pm.close_audio()
```

A sound keyed to a frame: queue the frame, then play at its token. The sound
starts `offset` seconds after the frame's projected presentation, and the
results report the frame's confirmed presentation time beside the sound's.

```python
token, _, _ = pm.queue_flip(w, pm.get_secs() + 0.1)
pm.play(beep, frame=token, offset=0)
```

Input: recording and a voice key.

```python
pm.open_audio(input=True, record_seconds=30)
pm.voice_key(0.1, minimum=10, window=0.005)   # 10 samples of 5 ms at >= 0.1
pm.start_recording()
...                                            # the trial
pm.stop_recording()
key = [e for e in pm.audio_results(wait=1) if e['kind'] == 'key']
samples, rate, first_sample_time = pm.get_recording()
```

## MATLAB and Octave

```matlab
info = PsychMetal('OpenAudio');                         % or OpenAudio, struct('input', true)
s = PsychMetal('MakeSound', PsychMetal('Tone', 1000, 0.05, info.rate));
v = PsychMetal('Play', s, PsychMetal('GetSecs') + 0.5); % sound, when, frame, offset, gain, repeats
events = PsychMetal('AudioResults', 1);                 % struct array, the fields below
PsychMetal('CloseAudio');
```

## Commands

| Python | MATLAB/Octave | |
|---|---|---|
| `audio_devices()` | `AudioDevices` | Devices with channels, rate, transport. On iOS, the current route. |
| `open_audio(device, rate, channels=2, buffer_frames=64, routes='wired', input=False, input_device, input_channels=1, record_seconds=60)` | `OpenAudio[, options]` | Opens output, and input if asked. Returns what is in use. |
| `close_audio()` | `CloseAudio` | Stops everything at once. |
| `audio_status()` | `AudioStatus` | Open, sounds, voices, clipped samples, recording. |
| `make_sound(samples, rate=None)` | `MakeSound, samples[, rate]` | Frames (x channels), float -1..1 or int16. Converted to the output's rate once, here. |
| `close_sound(s)` | `CloseSound, s` | Voices playing it finish. |
| `play(s, when, frame, offset, gain, repeats)` | `Play, s[, when, frame, offset, gain, repeats]` | Returns a voice id at once. `repeats=0` loops until stopped. |
| `stop_sound(voice=None, when=None)` | `StopSound[, voice, when]` | One voice or all, now or at a time, on a sample. |
| `modulate(voice, hz, phase=0, depth=1, when=None)` | `Modulate, voice, hz[, phase, depth, when]` | Amplitude modulation on GetSecs time; below. |
| `start_recording(when)`, `stop_recording(when)` | `StartRecording`, `StopRecording` | One recording at a time; a new one replaces the last. |
| `get_recording()` | `[x, rate, t0] = GetRecording` | A copy so far, frames x channels, and its first sample's time. |
| `voice_key(threshold, when, window=0.001, minimum=1)` | `VoiceKey, threshold[, when, window, minimum]` | One-shot; reports the first of `minimum` samples within `window` at or above `threshold`. |
| `input_recent(seconds=0.05)` | `[x, rate, t] = InputRecent[, seconds]` | The newest input (first channel), for meters and displays. |
| `audio_results(wait=0)` | `AudioResults[, wait]` | Events not yet reported. |
| `tone`, `click`, `white_noise`, `read_wav` | `Tone`, `Click`, `WhiteNoise` | Sound makers, the same code for both (`read_wav`: MATLAB has `audioread`). A seed repeats a white noise. |

Each event has `kind` ('sound start', 'sound end', 'recording start',
'recording end', 'key'), `id`, `requested` (NaN: at once), `time`, `status`
('on time', 'late', 'finished', 'stopped', 'full', 'refused', 'triggered'),
`frames` (a recording's length; for a key, its frame in the current recording),
`level` (a key's amplitude), `frameToken` and `framePresented`.

## What the times are

- A sound's `time` is when its first sample leaves the device: the output
  buffer's host time plus the latency the device reports. A sound whose time has
  passed starts at once and is reported `late` with its real start.
- A recording's and a key's times are when the sample entered the device: the
  input buffer's host time less the input latency the device reports. A voice
  key reports when the sound reached the input, not when the person began to
  speak: the microphone, its distance, the input gain and the threshold all
  move it.
- All are software times. A loudspeaker or headphone adds its own delay, and
  some devices report their latency wrongly. A photodiode and a microphone on
  a scope, or a loopback cable into an audio interface, measure the rest.

## Modulation

`modulate` multiplies a voice's samples by

    1 - depth * (1 - cos(2 pi hz t + phase)) / 2

with t each sample's GetSecs time: 1 at the peaks and 1 - depth at the
troughs, so `depth=1` runs from silence to the full sound. The cosine is
computed per sample from that sample's time, in the device callback, so the
phase is exact at every change and never drifts, and a modulated sound follows
the same function of time as anything drawn for a frame's presentation time.
A change takes effect on the sample nearest `when`, or at once (within a
device buffer); a change at once before the voice starts applies from its first
sample. A timed change replaces a timed change not yet due. `depth=0` ends
modulation; `hz=0, phase=pi, depth=1` silences a voice without stopping it.

To give a wave a phase on a clock that starts at `t0` (a trial's start, say),
pass `phase - 2 pi hz t0`, with whole cycles of `hz t0` removed first so the
result stays exact at large GetSecs times; `absolute_phase` in
python/modulation_match_demo.py does this. A change that moves the phase
makes the envelope jump, and the jump is audible as a click.

## Routes

Bluetooth and AirPlay outputs add a long, varying delay that the system does
not report reliably. `open_audio` refuses them unless `routes='any'`, and then
`info['timed']` is false and a warning says the times are not measurements. A
route or device change while audio is open warns at the next audio call, or at
closing if there is none; close
and reopen audio for timed work. On a Mac that includes another program changing
the device's sample rate or buffer size. Opening may set the device's rate and
buffer size, and waits up to two seconds for a new rate to take; a rate the
device does not offer is refused with the rates it does. Closing puts back the
values it found, unless something else has changed them since. The rate is shared by every program using the device.

## Threads and performance

The device callbacks take no locks and allocate nothing: commands and events
cross through fixed lock-free queues, and recording memory is allocated when
input opens. Audio has its own lock in the front ends, so a sound can be
scheduled from one thread while another draws or flips. Up to 256 sounds can
play at once (more are refused, and reported); the sum is clipped to -1..1 and
clipped samples are counted. Up to 2048 can be playing or waiting to play; `play`
refuses more until some end. A sound's memory is released when its voice ends,
even if its events were lost to a full event queue (`lostEvents` counts those).
Sound, voice, recording and key ids are never reused within a process, so an id
kept across `close_audio` and `open_audio` cannot name something new.

On iOS, playback uses a playback-only session (the silent switch does not mute
it). Input switches to play-and-record with output kept on the speaker (moved off the
receiver, the earpiece, if iOS puts it there; headphones keep it) and the
system's voice processing and automatic microphone gain off, so speech records
well below full scale. A phone call or Siri interrupts audio, and a
headphone plugged in or removed moves it; the next audio call, or closing,
warns. The notice
iOS posts when a session sets its own category does not. Independently of any
notice, an output callback that starts more than 50 ms after the previous
buffer ended means the output stopped for a while, and is reported the same way
on a Mac and an iPhone.

## Permissions

Input asks for microphone access the first time: on a Mac for the program
running Python, MATLAB or Octave (System Settings > Privacy & Security >
Microphone); on iOS for the app. A refusal is an error at `open_audio`, never
silent zeros, with its own identifier, `PsychMetal:Microphone` (`e.id` in
Python, `err.identifier` in MATLAB), so a program can tell it from a fault and
say where to turn access on. Without `input=True` nothing asks.

## Demos

`python/audio_demo.py` and `PsychMetalAudioDemo.m`: a live spectrogram of the
microphone; hold Record to record, Play to play it back, Stop, Quit or Escape.

`python/modulation_match_demo.py` and `PsychMetalModulationMatchDemo.m`: match
the phase or the frequency of a reference with a test, each either a Gaussian
blob whose brightness runs from grey to white or a tone modulated from silence
to full. Frequencies follow the measured refresh rate: a seen stimulus has an
even number of frames per cycle, its peak and trough on frames (at 60 Hz, 15,
7.5, ... 0.23 Hz; never 20). A dial sets the test's phase and a log
slider its frequency (mouse, finger or arrow keys); Match gives the error as a
percentage of a cycle, the shorter way round, or as delta f / f.
Phase errors include any audio or display delay the system does not report.

## Reading a recording during restart

A new recording replaces the previous one. Until the input callback has applied
that request, `GetRecording` / `get_recording` returns an empty new recording
with a NaN first-sample time. Once samples arrive, the returned prefix is final
and can be copied while capture continues.

After a detected route change, interruption or stop in the output, `AudioStatus` / `audio_status`
reports `timed=false` until audio is closed and reopened. The old rate and latency
metadata must not be used for timed work on the changed route.

Sound samples supplied to MakeSound / make_sound must be normalized to -1..1.
Use playback gain for amplification; the final mixed output is clipped and
counted. WhiteNoise / white_noise takes a finite nonnegative amplitude; zero
produces silence.
