"""Scheduled sound, recording and a voice key. See AUDIO.md.

One audio output, and optionally one input, per process, independent of the
window: audio can be open with no window, and a window with no audio. Every
time is GetSecs time, the clock of flip. Audio calls hold their own lock, so a
sound can be scheduled from one thread while another draws or flips.
"""
import time as _time

import numpy as _np

from . import _core, _check_abort, _fail, _number, _flag

__all__ = ['audio_devices', 'open_audio', 'close_audio', 'audio_status', 'make_sound', 'close_sound',
           'play', 'stop_sound', 'modulate', 'start_recording', 'stop_recording', 'get_recording', 'voice_key',
           'input_recent', 'audio_results', 'tone', 'click', 'white_noise', 'read_wav']


def _when(when):
    return None if when is None else _number(when, 'when must be a finite GetSecs time, or None for at once.')


def audio_devices():
    """List of devices: dicts with id, name, transport, outputChannels,
    inputChannels, rate, defaultOutput, defaultInput. On iOS, the current route."""
    return _core.audio_devices()


def open_audio(device=None, rate=None, channels=2, buffer_frames=64, routes='wired',
               input=False, input_device=None, input_channels=1, record_seconds=60):
    """info = open_audio(...) opens the audio output, and with input=True the input.

    device: an id from audio_devices(), or None for the system's output.
    rate: samples per second, or None for the device's own.
    buffer_frames: requested; info['bufferFrames'] is what the device granted.
    routes: 'wired' refuses Bluetooth and AirPlay, whose latency is long and
    variable; 'any' allows them, and info['timed'] is then False.
    input: also opens the input (recording and voice_key). On a Mac the first
    time asks for microphone access for the program running Python.
    record_seconds: memory for one recording, allocated now.

    info gives the rate, channels and buffer actually in use, the output and
    input latency (seconds) included in every reported time, and the devices."""
    if routes not in ('wired', 'any'):
        _fail("routes must be 'wired' or 'any'.")
    return _core.open_audio(device, rate, channels, buffer_frames, routes == 'any', _flag(input, 'input'),
                            input_device, input_channels, record_seconds)


def close_audio():
    """Stops every sound and recording at once and closes audio. Safe to call twice."""
    _core.close_audio()
    from . import _S
    if _S is not None:
        for movie in _S['movies'].values():
            movie['sounds'].clear()  # handles belonged to the closed audio Session


def audio_status():
    """Dict: open, info, sounds, voices (playing or waiting), clippedSamples,
    lostEvents, recording, recordedFrames."""
    return _core.audio_status()


def make_sound(samples, rate=None):
    """handle = make_sound(samples[, rate]) preloads a sound.

    samples: (frames,) or (frames, channels), float in -1..1 or int16. One
    channel plays on every output channel. rate: the samples' rate if not the
    output's; it is converted here, once, never while playing."""
    a = _np.asarray(samples)
    if a.dtype == _np.int16:
        a = a.astype(_np.float32) / 32768
    elif a.dtype.kind != 'f':
        _fail('Sound samples must be floating point in -1..1, or int16.')
    if a.dtype not in (_np.float32, _np.float64):
        a = a.astype(_np.float64)
    return _core.make_sound(a, rate)


def close_sound(sound):
    """Releases a sound. Voices already playing it finish."""
    _core.close_sound(sound)


def play(sound, when=None, frame=None, offset=0, gain=1, repeats=1):
    """voice = play(sound, when=None, frame=None, offset=0, gain=1, repeats=1)

    Schedules a sound and returns at once. when: a GetSecs time for its first
    sample, None for as soon as possible. frame: instead, the token of a frame
    queued with queue_flip; the sound starts offset seconds after
    that frame's projected presentation time, and audio_results reports both.
    The sound starts on the sample nearest its time. repeats=0 plays until
    stopped. gain multiplies the samples; the sum of all voices is clipped to
    -1..1, and audio_status counts clipped samples."""
    return _core.play(sound, _when(when), frame, offset, gain, repeats)


def stop_sound(voice=None, when=None):
    """Stops one voice, or every voice (None), at once or at a GetSecs time, on a sample."""
    _core.stop_sound(voice, _when(when))


def modulate(voice, hz, phase=0, depth=1, when=None):
    """Amplitude-modulates a voice from `when` (None: at once) on the nearest sample.

    Its samples are multiplied by 1 - depth * (1 - cos(2 pi hz t + phase)) / 2,
    t the GetSecs time of each sample: 1 at the peaks, 1 - depth at the
    troughs, so depth=1 runs from silence to the full sound. The phase is
    computed from each sample's time, so it is exact at every change and the
    same function of time as anything drawn for a frame's presentation time.
    depth=0 ends modulation. A change at once may come before the voice starts;
    it then applies from its first sample. A timed change replaces a timed
    change not yet due."""
    _core.modulate(voice, hz, phase, depth, _when(when))


def start_recording(when=None):
    """Starts recording on the sample nearest `when` (None: at once). One
    recording at a time; a new one replaces the last one's samples."""
    return _core.start_recording(_when(when))


def stop_recording(when=None):
    """Stops the recording on the sample nearest `when` (None: at once)."""
    _core.stop_recording(_when(when))


def get_recording():
    """(samples, rate, first_sample_time): a copy of the recording so far, as
    (frames, channels) float32. Works while it is still recording;
    first_sample_time is nan until it has started."""
    samples, rate, first, recording = _core.get_recording()
    return samples, rate, first


def voice_key(threshold, when=None, window=0.001, minimum=1):
    """Arms a one-shot voice key from `when` (None: at once). It triggers when
    `minimum` samples within `window` seconds reach `threshold` (absolute
    amplitude, 0..1), and audio_results reports a 'key' event at the first of
    them. minimum > 1 ignores single clicks. A new key replaces an armed one.

    The time is when the sound reached the input, by the device's reported
    latency; not when the person began to speak."""
    return _core.voice_key(threshold, _when(when), window, minimum)


def input_recent(seconds=0.05):
    """(samples, rate, end_time): the newest `seconds` of the first input
    channel, float32, and the GetSecs time just after the last sample. For level
    meters and live displays; it does not disturb a recording."""
    return _core.input_recent(seconds)


def audio_results(wait=0):
    """Every audio event not yet reported, oldest first, as dicts: kind ('sound
    start', 'sound end', 'recording start', 'recording end', 'key'), id,
    requested, time, status ('on time', 'late', 'finished', 'stopped', 'full',
    'refused', 'triggered'), frames, level, frameToken, framePresented.
    wait: seconds to wait for the first event if there are none; stop() ends it."""
    wait = _number(wait, 'wait must be a nonnegative number of seconds.', lambda v: v >= 0)
    deadline = _time.monotonic() + wait
    while True:
        _check_abort()
        events = _core.audio_results()
        if events or _time.monotonic() >= deadline:
            return events
        _time.sleep(0.001)


# --- sound makers: plain numpy, at a given rate -------------------------------------------

def tone(frequency, seconds, rate, amplitude=0.5, ramp=0.005):
    """A sine tone with raised-cosine onset and offset ramps (seconds)."""
    return _core.tone(frequency, seconds, rate, amplitude, ramp).reshape(-1)


def click(rate, seconds=0.001, amplitude=0.9):
    """A rectangular click: its onset is its first sample."""
    return _core.click(rate, seconds, amplitude).reshape(-1)


def white_noise(seconds, rate, amplitude=0.3, seed=None, ramp=0.005):
    """Gaussian white noise, clipped to -1..1, with ramps. A seed (a nonnegative
    integer) repeats the same noise."""
    return _core.white_noise(seconds, rate, amplitude, seed, ramp).reshape(-1)


def read_wav(path):
    """(samples, rate) from a 16-bit PCM WAV file, as (frames, channels) float in -1..1."""
    import wave
    with wave.open(str(path), 'rb') as f:
        if f.getsampwidth() != 2:
            _fail('read_wav reads 16-bit PCM WAV files.')
        data = _np.frombuffer(f.readframes(f.getnframes()), dtype='<i2')
        return data.reshape(-1, f.getnchannels()).astype(_np.float32) / 32768, f.getframerate()
