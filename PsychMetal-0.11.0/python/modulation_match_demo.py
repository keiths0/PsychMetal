#!/usr/bin/env python3
"""Match the phase or the frequency of a flickering blob or an amplitude-modulated tone.

    python3 modulation_match_demo.py

Each trial has a reference and a test, each either seen or heard. Seen: a
Gaussian blob whose brightness runs from the grey background up to white and
back. Heard: a tone whose loudness runs from silence up to full and back. Both
follow (1 + cos(2 pi f t + phase)) / 2, t the time since the trial began, which
is the presentation time of a frame: for the blob, the time of each frame; for
the tone, each sample's time on the same clock.

The display's refresh rate R is measured first, from confirmed frames. A seen
stimulus runs only at R / N for an even number N of frames per cycle, with a
frame on the cycle's start: every cycle then shows the same N frames, equally
spaced through it, among them its peak and its trough. At 60 Hz, 15 Hz (4
frames) is possible and 20 Hz (3) is not. Its phase is a whole number of
frames, a multiple of 1 / N of a cycle. The reference runs at one of seven
octaves of such frequencies, the fastest the highest at or below 16 Hz (at
60 or 120 Hz: 15, 7.5, 3.75, 1.875, 0.94, 0.47 and 0.23 Hz), at random. Each
frame shows the cycle's sample for its place on the refresh grid, so a missed
frame is skipped rather than delaying the rest, and seen and heard stay together.

Match phase: the test runs at the reference's frequency from a random phase,
and a dial sets its phase, a circular quantity: a turn is a cycle. A seen test
moves in steps of a frame, 1 / N of a cycle; a heard one continuously. The
dial's pointer starts each trial at a random angle, so it says nothing about
the answer. Match frequency: both start at a peak together, the test from a
random frequency, and a slider sets its frequency on a log scale across eight
octaves, which always include the reference octaves with room beyond them so
that no target sits at an end. A seen test takes the nearest frequency with an
even number of frames, so its steps are coarse near the top (at 60 Hz: 30, 15,
10, 7.5, 6 Hz ...); a heard one moves continuously. The eight octaves shift by
up to an octave either way each trial, so the knob's place says nothing exact
about the frequency.

Drag the dial round or the slider's knob along with the mouse or a finger, or
hold the arrow keys: right and up increase, left and down decrease, left and
right slowly (a tenth of a cycle or an octave a second), up and down quickly
(half). Match, Space or Return records the setting and shows the error: for
phase, the test's lead as a percentage of a cycle, the shorter way round the
circle (-50 to 50); for frequency, (f_test - f_reference) / f_reference as a
percentage. The next trial starts a moment later. The switches across the top
choose what is matched (Tab switches too) and whether the reference and the
test are seen or heard; changing one starts a new trial. Quit or Escape ends
the demo.

When both are heard, the reference tone is 400 Hz and the test 647 Hz, a ratio
of 1.6175, far from any harmonic or simple ratio; otherwise a heard stimulus is
400 Hz. When both are seen, the reference is on the left.

The errors are only as good as the times behind them. Times are those the
system reports: a loudspeaker or display that adds delay it does not report
shifts every phase setting by that delay, which at 15 Hz is 1.5% of a cycle
per millisecond. The blob's brightness is (1 + cos) / 2 in display values, not luminance; the times
of its peaks and troughs, which phase matching uses, are the same either way.

SPDX-License-Identifier: MIT
"""
import argparse
import math
import random
import sys

import numpy as np

import psychmetal as pm

FASTEST = 16                           # Hz: the fastest reference is the highest allowed at or below this
OCTAVES = 7                            # reference frequencies: that one and six octaves below
OCTAVE_SPAN = 8                        # the slider: an octave below the slowest reference to one above the fastest
CARRIERS = (400, 647)                  # Hz: a heard reference, and a heard test beside it
LEVEL = 0.25                           # each tone's peak amplitude
FEEDBACK = 1.2                         # seconds the error shows before the next trial
SLOW, FAST = 0.1, 0.5                  # dial turns, or slider octaves, per second with the arrow keys
GREY = 128
SWITCHES = (('mode', ('Phase', 'Frequency')), ('reference', ('Seen', 'Heard')), ('test', ('Seen', 'Heard')))
TITLES = {'mode': 'Match', 'reference': 'Reference', 'test': 'Test'}


def reference_frequencies(rate):
    """Seven octaves of R / N, N even, the fastest the highest at or below FASTEST."""
    n = max(2, 2 * math.ceil(rate / FASTEST / 2))
    return [rate / (n * 2 ** k) for k in range(OCTAVES)]


def displayable(hz, rate):
    """The frequency nearest hz (on a log scale) that a display at `rate` shows
    with an even number of frames per cycle."""
    n = rate / hz
    low = max(2, 2 * math.floor(n / 2))
    high = low + 2
    return rate / (low if abs(math.log(n / low)) <= abs(math.log(high / n)) else high)


def measure_refresh(w, ifi):
    """The display's refresh rate from the engine's grid of confirmed frames."""
    for _ in range(max(60, round(1 / ifi))):
        pm.draw_text(w, 'Measuring the display...', None, None, [220, 220, 225])
        pm.flip(w)
    _, period, samples = pm.grid_anchor(w)
    if samples < 30 or not math.isfinite(period) or period <= 0:
        raise RuntimeError('Could not measure the display refresh rate from confirmed frames.')
    return 1 / period


def waveform(t, hz, phase):
    """The modulation, 0 to 1, at time t after the trial's start."""
    return (1 + math.cos(2 * math.pi * hz * t + phase)) / 2


def absolute_phase(hz, phase, origin):
    """The phase on GetSecs time of the wave with this phase on a clock that
    starts at `origin`: cos(2 pi hz t + result) = cos(2 pi hz (t - origin) + phase).
    Whole cycles are removed before multiplying by 2 pi, so it stays exact at
    any GetSecs time."""
    cycles = hz * origin
    return math.remainder(phase - 2 * math.pi * (cycles - math.floor(cycles)), 2 * math.pi)


def phase_error(test, reference):
    """How far the test leads the reference, as a percentage of a cycle, the
    shorter way round the circle: -50 to 50."""
    cycles = (test - reference) / (2 * math.pi)
    return 100 * (cycles - math.floor(cycles + 0.5))


def frequency_error(test, reference):
    """(f_test - f_reference) / f_reference, as a percentage."""
    return 100 * (test - reference) / reference


def safe_area(w, rect):
    """The window less the screen's safe-area insets (a phone's camera housing and
    rounded corners; nothing on most Mac displays), in the window's pixels."""
    summary = pm.diagnostic(w)['summary']
    scale = float(summary.get('backingScaleFactor', 1) or 1)
    insets = np.asarray(summary.get('screenSafeAreaInsets', [0, 0, 0, 0]), dtype=float)
    if insets.shape != (4,) or not np.all(np.isfinite(insets)) or np.any(insets < 0):
        insets = np.zeros(4)
    top, left, bottom, right = insets * scale
    return [rect[0] + left, rect[1] + top, rect[2] - right, rect[3] - bottom]


def layout(rect):
    """Every control's place: switches[name] -> two boxes, dial (x, y, radius),
    slider (left, right, y, knob radius), buttons Match and Quit, and the blob
    boxes (left, centre, right)."""
    width, height = rect[2] - rect[0], rect[3] - rect[1]
    switches = {}
    if width >= height:                    # side by side, titles above
        gap = width * 0.025
        group = (width - 4 * gap) / 3
        top, bottom = height * 0.06, height * 0.13
        for k, (name, _) in enumerate(SWITCHES):
            left = gap + k * (group + gap)
            switches[name] = ([left, top, left + group / 2, bottom], [left + group / 2, top, left + group, bottom])
        y = height * 0.4
        slider = (width * 0.06, width * 0.44, height * 0.76, max(10, min(width, height) * 0.03))
    else:                                  # a phone upright: one row each, titles above
        left, right = width * 0.06, width * 0.94
        for k, (name, _) in enumerate(SWITCHES):
            top = height * (0.06 + 0.085 * k)
            middle = (left + right) / 2
            switches[name] = ([left, top, middle, top + height * 0.05], [middle, top, right, top + height * 0.05])
        y = height * 0.42
        slider = (width * 0.1, width * 0.9, height * 0.665, max(12, width * 0.035))
    radius = min(width * 0.19, height * 0.1)
    dial = (width * 0.27, height * 0.74, radius)
    buttons = {'Match': [width * 0.5, height * 0.71, width * 0.72, height * 0.81],
               'Quit': [width * 0.78, height * 0.71, width * 0.95, height * 0.81]}
    half = min(width, height) * 0.17
    blobs = {where: [x - half, y - half, x + half, y + half]
             for where, x in (('left', width * 0.3), ('centre', width * 0.5), ('right', width * 0.7))}
    ox, oy = rect[0], rect[1]                  # laid out from the area's corner

    def move(b):
        return [b[0] + ox, b[1] + oy, b[2] + ox, b[3] + oy]
    return dict(switches={k: tuple(move(b) for b in v) for k, v in switches.items()},
                dial=(dial[0] + ox, dial[1] + oy, dial[2]),
                slider=(slider[0] + ox, slider[1] + ox, slider[2] + oy, slider[3]),
                buttons={k: move(b) for k, b in buttons.items()}, blobs={k: move(b) for k, b in blobs.items()})


def inside(box, x, y):
    return box[0] <= x <= box[2] and box[1] <= y <= box[3]


class Trial:
    """One trial's reference, test, and dial (phase) or slider (frequency).
    origin is the presentation time of a frame and rate the measured refresh
    rate, so a seen stimulus's frames fall on its own cycle's grid."""

    def __init__(self, settings, origin, rng, rate, choices):
        self.mode, self.reference, self.test = settings['mode'], settings['reference'], settings['test']
        self.origin, self.rate = origin, rate
        self.reference_hz = rng.choice(choices)
        self.cycle = round(rate / self.reference_hz)            # the reference's frames per cycle, even
        self.foot = choices[0] / 2 ** (OCTAVE_SPAN - 1)        # the slider's foot before its shift
        self.turns = 0.0                                        # phase: the dial, from where it started
        self.pointer = rng.uniform(0, 2 * math.pi)              # its pointer's starting angle
        self.shift = rng.uniform(-1, 1)                         # frequency: the slider's range, in octaves
        self.position = 0.0                                     # its knob, 0 to 1
        self.dial_start = 0.0
        if self.mode == 'Phase':
            self.reference_phase = 2 * math.pi * rng.randrange(self.cycle) / self.cycle
            self.dial_start = rng.uniform(0, 2 * math.pi)       # the test's phase before any step
        else:
            self.reference_phase = 0.0                          # both start at a peak, on a frame
            hz = choices[0] * 2 ** rng.uniform(1 - OCTAVES, 0)  # anywhere among the references' octaves
            self.position = (math.log2(hz / self.foot) - self.shift) / OCTAVE_SPAN
        self.start = self.response()

    def turn(self, by):
        """Turns the dial (phase) by `by` turns."""
        self.turns += by

    def slide(self, to):
        """Puts the slider's knob (frequency) at `to`, 0 to 1."""
        self.position = min(max(to, 0.0), 1.0)

    def adjust(self, by):
        """The arrow keys: `by` turns of the dial, or octaves of the slider."""
        if self.mode == 'Phase':
            self.turn(by)
        else:
            self.slide(self.position + by / OCTAVE_SPAN)

    def _phase(self):
        """The test's phase, unwrapped: in whole frames when the test is seen."""
        phase = self.dial_start + 2 * math.pi * self.turns
        if self.test == 'Seen':
            step = 2 * math.pi / self.cycle
            phase = step * round(phase / step)
        return phase

    @property
    def test_hz(self):
        if self.mode == 'Phase':
            return self.reference_hz
        hz = self.foot * 2 ** (self.shift + OCTAVE_SPAN * self.position)
        return displayable(hz, self.rate) if self.test == 'Seen' else hz

    @property
    def test_phase(self):
        return self._phase() % (2 * math.pi) if self.mode == 'Phase' else self.reference_phase

    @property
    def pointer_angle(self):
        """Where the dial points: where it started, turned by the phase shown."""
        return self.pointer + self._phase() - self.dial_start

    @property
    def knob(self):
        """Where the slider's knob is: at the frequency shown."""
        return min(max((math.log2(self.test_hz / self.foot) - self.shift) / OCTAVE_SPAN, 0.0), 1.0)

    def level(self, presented, hz, phase):
        """A seen stimulus's brightness, 0 to 1, for the frame presented then:
        the sample for that frame's place in its cycle, counted in whole frames
        on the refresh grid, so every cycle repeats exactly with its peak at 1
        and its trough at 0. A seen stimulus has n frames per cycle, n even, and
        a phase of whole frames."""
        n = round(self.rate / hz)
        frame = round((presented - self.origin) * self.rate) + round(phase * n / (2 * math.pi))
        k = frame % n
        return 1.0 if k == 0 else 0.0 if 2 * k == n else (1 + math.cos(2 * math.pi * k / n)) / 2

    def response(self):
        return self.test_phase if self.mode == 'Phase' else self.test_hz

    def error(self):
        if self.mode == 'Phase':
            return phase_error(self.test_phase, self.reference_phase)
        return frequency_error(self.test_hz, self.reference_hz)

    def record(self, number, now):
        return dict(trial=number, mode=self.mode.lower(), reference=self.reference.lower(),
                    test=self.test.lower(), refresh_hz=self.rate, reference_hz=self.reference_hz,
                    reference_phase=self.reference_phase, start=self.start, response=self.response(),
                    error_percent=self.error(), seconds=now - self.origin)


def describe(record):
    if record['mode'] == 'phase':
        e = record['error_percent']
        lead = 'leads' if e > 0 else 'lags' if e < 0 else 'matches'
        return f"Phase error {e:+.1f}% of a cycle: the test {lead} (reference {record['reference_hz']:g} Hz)."
    return (f"Frequency error {record['error_percent']:+.1f}%: "
            f"{record['response']:.3f} Hz for {record['reference_hz']:g} Hz.")


def modulation_match_demo(seconds=None, seed=None):
    """Runs until Quit or Escape, or for `seconds` if given. Returns the trials:
    a list of dicts with trial, mode, reference, test, refresh_hz, reference_hz,
    reference_phase, start, response, error_percent and seconds."""
    rng = random.Random(seed)
    # Any output: with Bluetooth or AirPlay the demo still works and says that phases include a delay it cannot measure.
    info = pm.open_audio(routes='any')
    note = '' if info['timed'] else f"  {info['device']} adds a delay the system cannot measure: phases include it."
    try:
        w, rect, ifi = pm.open_window(None)
        try:
            return _run(w, rect, ifi, info['rate'], seconds, rng, note)
        finally:
            pm.close(w)
    finally:
        pm.close_audio()


class Tones:
    """The two carriers, looping from the start, silent unless asked: a heard
    stimulus is a change of modulation, never a start or a stop."""

    def __init__(self, rate):
        t = np.arange(int(rate)) / rate              # one second: whole cycles of any whole-Hz carrier
        self.sounds = [pm.make_sound(LEVEL * np.sin(2 * np.pi * hz * t)) for hz in CARRIERS]
        self.voices = [pm.play(s, repeats=0) for s in self.sounds]
        for v in self.voices:                        # silent from their first samples
            pm.modulate(v, 0, math.pi, 1)
        self.setting = [None, None]                  # None: silent

    def set(self, k, wave, origin=0.0):
        """wave (hz, phase) on the trial's clock from `origin`, or None for silence."""
        setting = None if wave is None else (*wave, origin)
        if setting == self.setting[k]:
            return
        self.setting[k] = setting
        if wave is None:                             # 1 - (1 - cos(pi)) / 2 = 0
            pm.modulate(self.voices[k], 0, math.pi, 1)
        else:
            pm.modulate(self.voices[k], wave[0], absolute_phase(wave[0], wave[1], origin), 1)

    def close(self):
        pm.stop_sound()
        for s in self.sounds:
            pm.close_sound(s)


def _run(w, rect, ifi, rate, seconds, rng, note=''):
    area = safe_area(w, rect)
    ox, oy = area[0], area[1]
    width, height = area[2] - area[0], area[3] - area[1]
    places = layout(area)
    size = max(14, height * 0.028)
    keys = {name: pm.kb_name(name) for name in
            ('ESCAPE', 'space', 'Return', 'tab', 'LeftArrow', 'RightArrow', 'UpArrow', 'DownArrow')}
    pm.background_color(w, GREY)
    refresh = measure_refresh(w, ifi)
    references = reference_frequencies(refresh)
    presented = pm.flip(w)[0] + 1 / refresh    # when the frame being drawn will be shown
    settings = {'mode': 'Phase', 'reference': 'Seen', 'test': 'Heard'}
    tones = Tones(rate)
    trials, shown = [], None

    def new_trial():
        return Trial(settings, presented, rng, refresh, references)

    trial = new_trial()
    resume = None                       # while the error shows: when the next trial starts
    touch = sys.platform == 'ios'
    fingers = {}
    was_down = held_keys = held_tab = False
    dragging, sliding, last_angle = False, False, 0.0
    end = pm.get_secs() + seconds if seconds else None
    then = pm.get_secs()
    try:
        while end is None or pm.get_secs() < end:
            now = pm.get_secs()
            dt, then = now - then, now
            if touch:
                events, dropped = pm.touch_events(w)
                if dropped:
                    fingers.clear()  # A release may have been lost; do not keep a button held.
                for _, finger, phase, fx, fy in events:
                    if phase < 2:
                        fingers[finger] = (fx, fy)
                    else:
                        fingers.pop(finger, None)
                down = bool(fingers)
                x, y = next(iter(fingers.values())) if fingers else (-1, -1)
            else:
                x, y, mouse = pm.get_mouse(w)
                down = bool(mouse[0])
            pressed = down and not was_down
            was_down = down
            _, _, code = pm.kb_check()
            confirm_key = bool(code[keys['space']] or code[keys['Return']])
            confirmed = confirm_key and not held_keys
            held_keys = confirm_key
            tab = bool(code[keys['tab']])
            if tab and not held_tab:                 # Tab: the other match, a new trial
                settings['mode'] = 'Frequency' if settings['mode'] == 'Phase' else 'Phase'
                trial, resume, shown = new_trial(), None, None
            held_tab = tab

            if code[keys['ESCAPE']] or (pressed and inside(places['buttons']['Quit'], x, y)):
                break
            for name, choices in SWITCHES:          # a switch: new settings, a new trial
                for box, choice in zip(places['switches'][name], choices):
                    if pressed and inside(box, x, y) and settings[name] != choice:
                        settings[name] = choice
                        trial, resume, shown = new_trial(), None, None

            if resume is not None:
                if now >= resume:
                    trial, resume = new_trial(), None
            else:
                cx, cy, radius = places['dial']
                left, right, sy, knob = places['slider']
                if pressed and trial.mode == 'Phase' and math.hypot(x - cx, y - cy) <= radius * 1.4:
                    dragging, last_angle = True, math.atan2(y - cy, x - cx)
                if pressed and trial.mode == 'Frequency' and left - 2 * knob <= x <= right + 2 * knob \
                        and abs(y - sy) <= 3 * knob:
                    sliding = True
                if dragging and down:
                    angle = math.atan2(y - cy, x - cx)
                    trial.turn(math.remainder(angle - last_angle, 2 * math.pi) / (2 * math.pi))
                    last_angle = angle
                if sliding and down:
                    trial.slide((x - left) / (right - left))
                key = {name: int(code[index]) for name, index in keys.items()}
                trial.adjust(dt * ((key['RightArrow'] - key['LeftArrow']) * SLOW +
                                   (key['UpArrow'] - key['DownArrow']) * FAST))
                if confirmed or (pressed and inside(places['buttons']['Match'], x, y)):
                    shown = trial.record(len(trials) + 1, now)
                    trials.append(shown)
                    resume = now + FEEDBACK
            if not down:
                dragging = sliding = False

            # The stimuli: the reference's and the test's waves on the trial's clock.
            running = resume is None
            ref_wave = (trial.reference_hz, trial.reference_phase)
            test_wave = (trial.test_hz, trial.test_phase)
            heard = [None, None]
            if running and trial.reference == 'Heard':
                heard[0] = ref_wave
            if running and trial.test == 'Heard':
                heard[1 if trial.reference == 'Heard' else 0] = test_wave
            for k in range(2):
                tones.set(k, heard[k], trial.origin)
            seen = []
            if trial.reference == 'Seen' and trial.test == 'Seen':
                seen = [('left', ref_wave, 'Reference'), ('right', test_wave, 'Test')]
            elif trial.reference == 'Seen':
                seen = [('centre', ref_wave, 'Reference')]
            elif trial.test == 'Seen':
                seen = [('centre', test_wave, 'Test')]
            for where, (hz, phase), label in seen:
                box = places['blobs'][where]
                if running:
                    pm.draw_gabor(w, [255, 255, 255, 255 * trial.level(presented, hz, phase)], box, 0.3)
                _label(w, label, (box[0] + box[2]) / 2, box[3] - size * 0.5, size * 0.8)
            if trial.reference == 'Heard' and trial.test == 'Heard':
                _label(w, f'Listen: reference {CARRIERS[0]} Hz, test {CARRIERS[1]} Hz', ox + width / 2, oy + height * 0.4, size,
                       width * 0.94)
            elif trial.reference == 'Heard' or trial.test == 'Heard':
                role = 'reference' if trial.reference == 'Heard' else 'test'
                _label(w, f'The {role} is the {CARRIERS[0]} Hz tone.', ox + width / 2, oy + height * 0.585, size * 0.8,
                       width * 0.94)

            for name, choices in SWITCHES:
                boxes = places['switches'][name]
                _label(w, TITLES[name], (boxes[0][0] + boxes[1][2]) / 2, boxes[0][1] - size * 1.15, size * 0.75)
                for box, choice in zip(boxes, choices):
                    on = settings[name] == choice
                    pm.fill_rect(w, [60, 140, 220] if on else [70, 70, 90], box)
                    pm.frame_rect(w, [150, 150, 170], box, 2)
                    _centred(w, choice, box, size * 0.8)
            if trial.mode == 'Phase':               # a dial: phase is circular
                cx, cy, radius = places['dial']
                pm.fill_oval(w, [70, 70, 90] if running else [90, 90, 100],
                             [cx - radius, cy - radius, cx + radius, cy + radius])
                pm.frame_oval(w, [150, 150, 170], [cx - radius, cy - radius, cx + radius, cy + radius], 3)
                angle = trial.pointer_angle
                pm.draw_lines(w, np.array([[cx + 0.2 * radius * math.cos(angle), cx + 0.9 * radius * math.cos(angle)],
                                           [cy + 0.2 * radius * math.sin(angle), cy + 0.9 * radius * math.sin(angle)]]),
                              4, [240, 240, 245])
                _label(w, 'phase', cx, cy + radius + size * 0.3, size * 0.75)
            else:                                   # a slider: frequency has ends
                left, right, sy, knob = places['slider']
                pm.fill_rect(w, [70, 70, 90], [left, sy - knob * 0.3, right, sy + knob * 0.3])
                pm.frame_rect(w, [150, 150, 170], [left, sy - knob * 0.3, right, sy + knob * 0.3], 1)
                kx = left + trial.knob * (right - left)
                pm.fill_oval(w, [225, 225, 235] if running else [150, 150, 160], [kx - knob, sy - knob, kx + knob, sy + knob])
                pm.frame_oval(w, [110, 110, 130], [kx - knob, sy - knob, kx + knob, sy + knob], 2)
                _label(w, 'frequency', (left + right) / 2, sy + knob * 1.3, size * 0.75)
            for name, box in places['buttons'].items():
                pm.fill_rect(w, [70, 70, 90], box)
                pm.frame_rect(w, [150, 150, 170], box, 2)
                _centred(w, name, box, size)
            status = describe(shown) if shown else ('Turn the dial' if trial.mode == 'Phase' else 'Slide the knob') + \
                f' until the test matches the reference, then Match. Display {refresh:.2f} Hz.'
            pm.draw_text(w, f'Trial {len(trials) + (0 if resume else 1)}.  {status}{note}', None, oy + height * 0.91,
                         [235, 235, 240], size * 0.8, wrap_width=width * 0.92)
            presented = pm.flip(w)[0] + 1 / refresh
    finally:
        tones.close()
    return trials


def _fit(w, text, size, width):
    """The text's size, made smaller if need be to fit `width`, and its extent."""
    (_, _, tw, th), _ = pm.text_bounds(w, text, size)
    if width and tw > width:
        size *= width / tw
        (_, _, tw, th), _ = pm.text_bounds(w, text, size)
    return size, tw, th


def _label(w, text, x, y, size, width=None):
    """Text centred on x, its top at y, no wider than `width`."""
    size, tw, _ = _fit(w, text, size, width)
    pm.draw_text(w, text, x - tw / 2, y, [225, 225, 230], size)


def _centred(w, text, box, size):
    """Text centred in a box, made smaller if need be to fit it."""
    size, tw, th = _fit(w, text, size, 0.88 * (box[2] - box[0]))
    pm.draw_text(w, text, (box[0] + box[2] - tw) / 2, (box[1] + box[3] - th) / 2, [240, 240, 245], size)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seconds', type=float, default=None, help='end after this long (default: until Quit)')
    parser.add_argument('--seed', type=int, default=None, help='the random sequence, for a repeatable run')
    parser.add_argument('--csv', default=None, help='also write the trials to this new file')
    parser.add_argument('--threaded', action='store_true')
    args = parser.parse_args()
    trials = pm.run(modulation_match_demo, args.seconds, args.seed, threaded=args.threaded)
    for t in trials:
        print(f"{t['trial']:3d}  {t['mode']:9s}  {t['reference']}->{t['test']}  {t['reference_hz']:5g} Hz  "
              f"error {t['error_percent']:+6.1f}%  {t['seconds']:5.1f} s")
    if args.csv and trials:
        import csv
        with open(args.csv, 'x', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=list(trials[0]))
            writer.writeheader()
            writer.writerows(trials)


if __name__ == '__main__':
    main()
