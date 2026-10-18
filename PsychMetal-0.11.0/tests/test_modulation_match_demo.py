"""The modulation matching demo against the scripted engine, with a scripted
mouse: a phase match left alone, a phase match after a quarter turn of the
dial, a frequency match with the slider's knob put in the middle, and one with
both heard; then Quit. Checks each trial's response and error, the frequencies
a display can show (an even number of frames per cycle, peak and trough on
frames), and the arithmetic that puts the tone on the blob's clock."""
import math
import os
import random
import time
from unittest.mock import patch

import numpy as np
import psychmetal as pm
import modulation_match_demo as demo

# The clock conversion: the tone's phase on GetSecs time gives the trial's wave.
rng = random.Random(3)
for _ in range(200):
    hz, phase, origin = rng.uniform(0.1, 32), rng.uniform(-10, 10), rng.uniform(0, 2e6)
    p = demo.absolute_phase(hz, phase, origin)
    assert -math.pi <= p <= math.pi
    for dt in (0, 0.0123, 1.7):
        assert abs((1 + math.cos(2 * math.pi * hz * (origin + dt) + p)) / 2 - demo.waveform(dt, hz, phase)) < 1e-6
assert abs(demo.phase_error(0.1 * 2 * math.pi, 0) - 10) < 1e-9
assert abs(demo.phase_error(0.9 * 2 * math.pi, 0) + 10) < 1e-9          # 90% ahead is 10% behind
assert abs(demo.phase_error(5 * 2 * math.pi + 1, 1)) < 1e-9
assert abs(demo.frequency_error(4.4, 4) - 10) < 1e-9

# What a display can show: R / N, N even, so each cycle has its peak and trough on frames.
assert demo.reference_frequencies(60) == [15, 7.5, 3.75, 1.875, 0.9375, 0.46875, 0.234375]
assert demo.reference_frequencies(120) == demo.reference_frequencies(60)
assert demo.reference_frequencies(144)[0] == 14.4 and demo.reference_frequencies(100)[0] == 12.5
assert demo.displayable(20, 60) == 15 and demo.displayable(25, 60) == 30 and demo.displayable(9, 60) == 10
assert demo.displayable(100, 60) == 30 and demo.displayable(0.01, 60) == 60 / 6000
for rate in (59.94, 60, 100, 120, 144, 165):
    choices = demo.reference_frequencies(rate)
    assert len(choices) == 7 and choices[0] <= 16 and choices[0] * 2 > 16 - 1e-9 or rate / choices[0] == 2
    for hz in choices + [demo.displayable(f, rate) for f in np.geomspace(0.05, 100, 200)]:
        n = rate / hz
        assert abs(n - round(n)) < 1e-9 and round(n) % 2 == 0 and round(n) >= 2
    for k, hz in enumerate(choices):
        trial = demo.Trial({'mode': 'Phase', 'reference': 'Seen', 'test': 'Seen'}, 1000.0, random.Random(k), rate, choices)
        n = round(rate / hz)
        # Two cycles of frames, with presentation times jittered by a tenth of a frame.
        levels = [trial.level(1000.0 + (j + rng.uniform(-0.1, 0.1)) / rate, hz, 0) for j in range(2 * n)]
        assert max(levels) == 1 and min(levels) < 1e-12 and levels[:n] == levels[n:]
        assert sorted(levels) == sorted(levels[:n] * 2)
        # At each frame, the blob's value is the tone's function of time, at any phase of whole frames.
        for m in (0, 1, n // 2, n - 1):
            phase = 2 * math.pi * m / n
            for j in range(n):
                assert abs(trial.level(1000.0 + j / rate, hz, phase) - demo.waveform(j / rate, hz, phase)) < 1e-9
# A seen test's phase moves in whole frames; a heard test's continuously.
for test, whole in (('Seen', True), ('Heard', False)):
    trial = demo.Trial({'mode': 'Phase', 'reference': 'Seen', 'test': test}, 5.0, random.Random(2), 60, demo.reference_frequencies(60))
    for turns in np.linspace(0, 1, 37):
        trial.turns = turns
        steps = trial.test_phase / (2 * math.pi / trial.cycle)
        assert (abs(steps - round(steps)) < 1e-9) == whole or turns == 0 and not whole
    steps = trial.reference_phase / (2 * math.pi / trial.cycle)
    assert abs(steps - round(steps)) < 1e-9
# A seen test's frequency is always displayable; the slider stays put between.
trial = demo.Trial({'mode': 'Frequency', 'reference': 'Heard', 'test': 'Seen'}, 5.0, random.Random(4), 60, demo.reference_frequencies(60))
for position in np.linspace(0, 1, 101):
    trial.slide(position)
    assert trial.test_hz == demo.displayable(trial.test_hz, 60) and trial.reference_phase == trial.test_phase == 0

# The tones are silent until a stimulus is heard, and silent again after: what
# the device played, read back through the scripted loopback.
os.environ['PM_MOCK_AUDIO_LEVEL'] = '0'
try:
    pm.open_audio(input=True, record_seconds=2)
finally:
    del os.environ['PM_MOCK_AUDIO_LEVEL']


def heard(seconds=0.1):
    pm.start_recording()
    time.sleep(seconds)
    pm.stop_recording()
    while not any(e['kind'] == 'recording end' for e in pm.audio_results(wait=0.05)):
        pass
    return np.abs(pm.get_recording()[0]).max()


tones = demo.Tones(pm.audio_status()['info']['rate'])
time.sleep(0.02)
assert heard() == 0, 'both tones must start silent'
tones.set(1, (4, 0), pm.get_secs())
assert heard() > 0.1
tones.set(1, None)
time.sleep(0.02)
assert heard() == 0, 'a tone must fall silent when no longer heard'
tones.close()
pm.close_audio()

places = demo.layout([0, 0, 800, 600])
cx, cy, radius = places['dial']
left, right, sy, knob = places['slider']


def centre(box):
    return ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2, True)


def click(box):
    return [centre(box), (5, 595, False)]


def drag(start, stop, steps=8):
    """Round the dial from angle start to stop, in radians."""
    path = [(cx + 0.8 * radius * math.cos(a), cy + 0.8 * radius * math.sin(a), True)
            for a in np.linspace(start, stop, steps)]
    return path + [(5, 595, False)]


idle = [(5, 595, False)] * 8
script = (idle + click(places['buttons']['Match']) + idle +
          drag(0, math.pi / 2) + click(places['buttons']['Match']) + idle +
          click(places['switches']['mode'][1]) + idle +
          [((left + right) / 2, sy + knob * 0.5, True)] * 3 + [(5, 595, False)] +
          click(places['buttons']['Match']) + idle +
          click(places['switches']['reference'][1]) + click(places['switches']['test'][1]) + idle +
          click(places['buttons']['Match']) + idle + click(places['buttons']['Quit']))
calls = iter(script)
real = pm.get_mouse


def mouse(w):
    real(w)
    x, y, down = next(calls)
    return x, y, np.array([down, False, False])


made = []


class Spy(demo.Trial):
    def __init__(self, *args):
        super().__init__(*args)
        made.append(self)


with patch.object(pm, 'get_mouse', mouse), patch.object(demo, 'FEEDBACK', 0.02), patch.object(demo, 'Trial', Spy):
    trials = pm.run(demo.modulation_match_demo, 30, 11)
assert [t['trial'] for t in trials] == [1, 2, 3, 4], trials
assert [t['mode'] for t in trials] == ['phase', 'phase', 'frequency', 'frequency']
assert [(t['reference'], t['test']) for t in trials] == [('seen', 'heard')] * 3 + [('heard', 'heard')]
for t in trials:                                     # the scripted display: 60 Hz, measured
    assert abs(t['refresh_hz'] - 60) < 0.01 and t['seconds'] > 0
    assert t['reference_hz'] in demo.reference_frequencies(t['refresh_hz'])
one, two, three, four = trials
assert one['response'] == one['start']
assert abs(one['error_percent'] - demo.phase_error(one['start'], one['reference_phase'])) < 1e-9
# A quarter turn: a quarter cycle, the response within one cycle.
assert 0 <= two['response'] < 2 * math.pi
assert abs(math.remainder(two['response'] - (two['start'] + math.pi / 2), 2 * math.pi)) < 1e-9
assert abs(two['error_percent'] - demo.phase_error(two['response'], two['reference_phase'])) < 1e-9
# The knob in the middle of the slider: four octaves above its range's foot.
slider = [t for t in made if t.mode == 'Frequency' and t.start == three['start']][0]
assert slider.position == 0.5 and -1 <= slider.shift <= 1
assert abs(three['response'] - slider.foot * 2 ** (slider.shift + 4)) < 1e-9
assert abs(three['error_percent'] - 100 * (three['response'] / three['reference_hz'] - 1)) < 1e-9
assert 0 < four['response'] and four['reference_phase'] == 0
assert not pm.audio_status()['open']
# The slider's range always holds every target and every start, whatever its shift.
for t in made:
    if t.mode == 'Frequency':
        choices = demo.reference_frequencies(t.rate)
        assert 0 <= (math.log2(t.start / t.foot) - t.shift) / demo.OCTAVE_SPAN <= 1
        assert t.foot * 2 ** t.shift <= min(choices) and t.foot * 2 ** (t.shift + demo.OCTAVE_SPAN) >= max(choices)
print('PASS: modulation matching demo: frequencies the measured display can show (even frames per cycle, peak and '
      'trough on frames), the dial (phase, whole frames when seen), the slider (log, shifted range), errors the '
      'shorter way round, switches, both heard, quit; the tone and the blob share one clock.')
