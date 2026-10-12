"""The audio demo against the scripted engine, with a scripted mouse: hold
Record, let go, click Play, then Quit. The scripted device plays and records
with a loopback, so the whole path runs: recording, conversion to a sound,
playback and the reported times."""
from unittest.mock import patch

import numpy as np
import psychmetal as pm
import audio_demo

# Playback raises a quiet recording to half scale, at most +30 dB; silence and loud recordings stay put.
assert audio_demo.playback_gain(np.array([0.01, -0.05])) == (10.0, 0.05)
assert audio_demo.playback_gain(np.array([1e-4]))[0] == 30.0
assert audio_demo.playback_gain(np.zeros(5)) == (1.0, 0.0) and audio_demo.playback_gain(np.array([0.9]))[0] < 1

# Cached grids produce identical spectrogram pixels and are reused per frame.
rng = np.random.default_rng(41)
x = rng.normal(0, .05, audio_demo.FFT)
lut = audio_demo.colormap()
window = np.hanning(len(x))
magnitude = np.abs(np.fft.rfft(x * window)) / (window.sum() / 2)
level = np.interp(np.linspace(audio_demo.TOP_HZ, 0, 256),
                  np.fft.rfftfreq(len(x), 1 / 48000), 20 * np.log10(magnitude + 1e-12))
indices = np.clip((level - audio_demo.FLOOR_DB) /
                  (audio_demo.CEILING_DB - audio_demo.FLOOR_DB) * 255, 0, 255).astype(int)
assert np.array_equal(audio_demo.spectrum_column(x, 48000, 256, lut), lut[indices])
assert audio_demo.spectrum_grid(len(x), 48000, 256) is audio_demo.spectrum_grid(len(x), 48000, 256)

buttons = audio_demo.buttons_for([0, 0, 800, 600])
centre = {n: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) for n, b in buttons.items()}
script = ([(10, 10, False)] * 5 + [(*centre['Record'], True)] * 20 + [(10, 10, False)] * 10 +
          [(*centre['Play'], True)] + [(10, 10, False)] * 30 + [(*centre['Quit'], True)])
calls = iter(script)
real = pm.get_mouse


def mouse(w):
    real(w)
    x, y, down = next(calls)
    return x, y, np.array([down, False, False])


with patch.object(pm, 'get_mouse', mouse):
    result = pm.run(audio_demo.audio_demo, 10)
assert result['log'] == ['record', 'play'], result
# Held for 20 frames at 60 Hz: the recording is a third of a second, give or take a frame.
assert abs(result['recorded_seconds'] - 20 / 60) < 2 / 60, result
assert np.isfinite(result['played_at'])
assert not pm.audio_status()['open'] and result['microphone']

# Microphone access refused: the demo says where to turn it on and ends, rather than failing.
import contextlib, io, os
os.environ['PM_MOCK_MICROPHONE'] = 'denied'
try:
    said = io.StringIO()
    with contextlib.redirect_stdout(said):
        result = pm.run(audio_demo.audio_demo, 10)
finally:
    del os.environ['PM_MOCK_MICROPHONE']
assert result == dict(log=[], recorded_seconds=None, played_at=None, microphone=False), result
assert 'needs the microphone' in said.getvalue() and not pm.audio_status()['open']
try:
    os.environ['PM_MOCK_MICROPHONE'] = 'denied'
    pm.open_audio(input=True)
    raise AssertionError('input opened with the microphone refused')
except pm.PsychMetalError as e:
    assert e.id == 'PsychMetal:Microphone', e.id
finally:
    del os.environ['PM_MOCK_MICROPHONE']
info = pm.open_audio()                     # output alone never asks
pm.close_audio()
print('PASS: audio demo records while the button is held, plays the recording back and quits; '
      'a refused microphone is PsychMetal:Microphone and the demo explains it.')
