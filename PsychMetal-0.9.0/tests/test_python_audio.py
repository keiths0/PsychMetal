"""Python audio against the scripted engine: the real host session and real-time
core, driven by a simulated 48 kHz device on the real clock with a loopback
input. Checks the arithmetic from call to reported time, not a sound card."""
import os
import threading
import time
import warnings

import numpy as np
import psychmetal as pm

RATE = 48000
SAMPLE = 1 / RATE


def raises(fn, *args, message=None, **kw):
    try:
        fn(*args, **kw)
    except pm.PsychMetalError as e:
        assert message is None or message in str(e), f'{message!r} not in {str(e)!r}'
        return e
    raise AssertionError(f'{getattr(fn, "__name__", fn)} accepted invalid input')


def events_until(kind, count=1, seconds=2.0):
    """Collect events until `count` of `kind` have arrived."""
    got, deadline = [], time.monotonic() + seconds
    while sum(e['kind'] == kind for e in got) < count:
        assert time.monotonic() < deadline, f'no {kind!r} event: {got}'
        got += pm.audio_results(wait=0.05)
    return got


raises(pm.make_sound, np.zeros(10), message='Audio is not open')
devices = pm.audio_devices()
assert [d['name'] for d in devices] == ['Scripted Speakers', 'Scripted Microphone'] and devices[0]['defaultOutput']
assert pm.audio_status()['open'] is False

info = pm.open_audio()
assert info['rate'] == RATE and info['channels'] == 2 and info['timed'] and not info['input']
assert info['outputLatency'] == 0.005 and info['bufferFrames'] == 64
raises(pm.open_audio, message='already open')
raises(pm.start_recording, message='input is not open')

# Sounds: float, int16, stereo; conversion from another rate happens once, at load.
click = pm.make_sound(pm.click(RATE))
quiet = pm.make_sound((np.ones(48) * 1000).astype(np.int16))
stereo = pm.make_sound(np.zeros((480, 2), np.float32))
raises(pm.make_sound, np.zeros((10, 3)), message='one channel, or as many as the audio output')
raises(pm.make_sound, np.array([0, np.nan]), message='finite')
raises(pm.make_sound, np.array([1.01]), message='normalized')
raises(pm.make_sound, np.array([-1.01], dtype=np.float32), message='normalized')
raises(pm.make_sound, np.arange(4), message='floating point')
half = pm.make_sound(np.zeros(24000), rate=24000)
assert pm.audio_status()['sounds'] == 4

# A sound at a time starts on the sample nearest it, and ends after its last sample.
t = pm.get_secs() + 0.05
v = pm.play(click, when=t)
got = events_until('sound end')
start, end = [e for e in got if e['id'] == v]
assert start['kind'] == 'sound start' and start['status'] == 'on time' and abs(start['time'] - t) <= SAMPLE / 2 + 1e-9
assert end['status'] == 'finished' and abs(end['time'] - (start['time'] + 48 * SAMPLE)) < 1e-9
# Too late: it starts at once and says so.
v = pm.play(quiet, when=pm.get_secs() - 1)
late = [e for e in events_until('sound end') if e['id'] == v and e['kind'] == 'sound start'][0]
assert late['status'] == 'late' and late['time'] > late['requested'] + 0.9

# Until stopped; stopped on a sample at a time.
v = pm.play(quiet, repeats=0)
time.sleep(0.03)
stop_at = pm.get_secs() + 0.02
pm.stop_sound(v, when=stop_at)
stopped = [e for e in events_until('sound end') if e['kind'] == 'sound end'][-1]
assert stopped['status'] == 'stopped' and abs(stopped['time'] - stop_at) <= SAMPLE / 2 + 1e-9
pm.stop_sound(v)                    # already ended: nothing to do
raises(pm.stop_sound, 10 ** 6, message='No sound was played')
raises(pm.play, 999, message='Invalid or closed sound')
raises(pm.play, click, when=float('inf'))
raises(pm.play, click, frame=1, message='not queued')
raises(pm.play, click, offset=0.1, message='offset needs a time or a frame')
pm.close_sound(half)
raises(pm.close_sound, half, message='Invalid or closed')

# Keyed to a frame: the sound starts offset seconds after the frame's projected
# presentation, and the results give both.
w, _, ifi = pm.open_window(0)
token, _, _ = pm.queue_flip(w, pm.get_secs() + 0.1)
v = pm.play(click, frame=token, offset=0.002)
pm.queue_results(w)
start = [e for e in events_until('sound end') if e['id'] == v and e['kind'] == 'sound start'][0]
assert start['frameToken'] == token and np.isfinite(start['framePresented'])
assert abs(start['time'] - (start['framePresented'] + 0.002)) <= SAMPLE / 2 + 1e-9
pm.close(w)
pm.close_audio()
pm.close_audio()
print('PASS: scheduled sounds start and stop on the nearest sample, late starts, repeats, frame-keyed sounds, sound lifetimes.')

# Input: recording, the voice key and the monitor, with the simulated loopback.
info = pm.open_audio(input=True, record_seconds=2)
assert info['input'] and info['inputRate'] == RATE and info['inputLatency'] == 0.003
samples, rate, end_time = pm.input_recent(0.02)
assert samples.shape == (960,) and rate == RATE and abs(end_time - pm.get_secs()) < 0.05
assert 0.03 < np.abs(samples).max() <= 0.051              # the quiet 440 Hz tone
raises(pm.input_recent, 5, message='at most')

r = pm.start_recording()
key = pm.voice_key(0.5, minimum=8, window=0.002)
time.sleep(0.05)
t = pm.get_secs() + 0.05
v = pm.play(pm.make_sound(np.full(480, 0.8)), when=t)
got = events_until('key')
time.sleep(0.05)
pm.stop_recording()
got += events_until('recording end')
key_event = [e for e in got if e['kind'] == 'key'][0]
started = [e for e in got if e['kind'] == 'sound start'][0]
# The loopback hears the sound in the buffer it is played from: the input stamps
# it output latency + input latency earlier than its output time.
assert abs(key_event['time'] - (started['time'] - 0.008)) <= SAMPLE + 1e-9 and key_event['status'] == 'triggered'
assert 0.74 <= key_event['level'] <= 0.86 and np.isfinite(key_event['frames'])
samples, rate, first = pm.get_recording()
ended = [e for e in got if e['kind'] == 'recording end'][0]
assert ended['status'] == 'stopped' and samples.shape == (int(ended['frames']), 1)
at = int(key_event['frames'])
assert samples[at, 0] > 0.5 and abs(samples[at - 1, 0]) < 0.06
assert abs(first + at / RATE - key_event['time']) < 1e-6

# Recording memory fills: it stops and says so.
pm.start_recording()
full = [e for e in events_until('recording end', seconds=4) if e['kind'] == 'recording end'][0]
assert full['status'] == 'full' and full['frames'] == 2 * RATE
raises(pm.voice_key, 0, message='threshold')
raises(pm.voice_key, 0.5, window=1, message='window')
raises(pm.voice_key, 0.5, window=0.001, minimum=100, message='minimum')

# stop() ends a wait for audio events.
pm.start(lambda: None).join()
worker = pm.start(lambda: pm.audio_results(wait=5))
time.sleep(0.05)
t0 = time.monotonic()
pm.stop()
worker.join(1)
assert not worker.is_alive() and time.monotonic() - t0 < 0.5
pm.start(lambda: None).join()
pm.close_audio()

# Bluetooth: refused unless asked for, then untimed with a warning.
os.environ['PM_MOCK_AUDIO_ROUTE'] = 'bluetooth'
try:
    raises(pm.open_audio, message='Bluetooth')
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter('always')
        info = pm.open_audio(routes='any')
    assert not info['timed'] and any('PsychMetal:AudioRoute' in str(c.message) for c in caught)
    pm.close_audio()
    # Under Python's own filters, not 'always': every route warning shows, not only the first from a place.
    with warnings.catch_warnings(record=True) as caught:
        for _ in range(3):
            pm.open_audio(routes='any')
            pm.close_audio()
    assert sum('PsychMetal:AudioRoute' in str(c.message) for c in caught) == 3, [str(c.message) for c in caught]
finally:
    del os.environ['PM_MOCK_AUDIO_ROUTE']
raises(pm.open_audio, routes='bluetooth', message="routes must be")

# An interruption with no audio call after it (a steady tone, then Quit): closing reports it, once.
os.environ['PM_MOCK_AUDIO_INTERRUPT'] = '0.02'
try:
    for check_first in (False, True):
        with warnings.catch_warnings(record=True) as caught:
            pm.open_audio()
            time.sleep(0.1)
            if check_first:
                assert not pm.audio_status()['info']['timed']
            pm.close_audio()
        said = [str(c.message) for c in caught if 'interrupted' in str(c.message)]
        assert len(said) == 1, said
finally:
    del os.environ['PM_MOCK_AUDIO_INTERRUPT']
# The output stopping for a while with nothing reported (a stall, an interruption
# the system kept quiet about): found from the gap between callbacks.
os.environ['PM_MOCK_AUDIO_GAP'] = '0.02'
try:
    with warnings.catch_warnings(record=True) as caught:
        pm.open_audio()
        time.sleep(0.2)
        assert not pm.audio_status()['info']['timed']
        pm.close_audio()
    said = [str(c.message) for c in caught if 'stopped for a while' in str(c.message)]
    assert len(said) == 1, said
finally:
    del os.environ['PM_MOCK_AUDIO_GAP']
print('PASS: recording on exact samples, voice key time and frame within a recording, memory full, input monitor, stop(), route refusal, every route warning, an interruption reported at close, an unreported stop found from the callbacks.')

# Modulation: what the device played, read back through the loopback (which stamps
# a sample output latency + input latency before it played), against
# 1 - depth * (1 - cos(2 pi hz t + phase)) / 2 at each sample's GetSecs time.
os.environ['PM_MOCK_AUDIO_LEVEL'] = '0'
try:
    pm.open_audio(input=True, record_seconds=2)
finally:
    del os.environ['PM_MOCK_AUDIO_LEVEL']
flat = pm.make_sound(np.full(4800, 0.5))
v = pm.play(flat, repeats=0)
pm.modulate(v, 7, phase=1.1, depth=0.8)          # at once, before the voice has started
change = pm.get_secs() + 0.15
pm.modulate(v, 31, phase=-2, depth=1, when=change)
pm.start_recording()
time.sleep(0.3)
pm.stop_recording()
events_until('recording end')
samples, rate, first = pm.get_recording()
played = first + np.arange(len(samples)) / rate + 0.008
heard = samples[:, 0]
on = heard > 0                                   # the voice may start after the recording
assert on.sum() > 0.25 * rate and played[on][0] < change - 0.05
envelope = lambda t, hz, phase, depth: 1 - depth * (1 - np.cos(2 * np.pi * hz * t + phase)) / 2
nearest = np.round((change - first - 0.008) * rate)          # the change's sample in the recording
index = np.arange(len(samples))
want = 0.5 * np.where(index < nearest, envelope(played, 7, 1.1, 0.8), envelope(played, 31, -2, 1))
assert np.abs(heard[on] - want[on]).max() < 1e-5, np.abs(heard[on] - want[on]).max()
raises(pm.modulate, v, -1, message='hz must be')
raises(pm.modulate, v, 10, depth=1.5, message='depth must be')
raises(pm.modulate, v, 10, phase=float('nan'))
raises(pm.modulate, 10 ** 6, 10, message='No sound was played')
pm.stop_sound()
time.sleep(0.02)
pm.modulate(v, 10)                               # ended: nothing to do
pm.close_audio()
print('PASS: modulation on GetSecs time, read back sample for sample through the loopback; a timed change on its sample; checks.')
