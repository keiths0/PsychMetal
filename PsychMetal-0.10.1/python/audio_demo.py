#!/usr/bin/env python3
"""A live spectrogram of the microphone, a recorder and a player.

    python3 audio_demo.py

The spectrogram scrolls from right to left, 0 to 8 kHz from bottom to top.
Hold the mouse button down on Record to record; letting go stops it. Play plays
the recording; Stop stops it. Quit or Escape ends the demo. On a touch screen a
finger on a button does what the mouse button does, and three fingers quit. On a
Mac the first run asks for microphone access for the program running Python.

The recording starts and stops on the samples nearest the moments the button
went down and up (as Python saw them, about one frame later). The text below
the buttons gives the recording's length and the time its playback started.

SPDX-License-Identifier: MIT
"""
from functools import lru_cache

import argparse
import sys

import numpy as np

import psychmetal as pm

FFT = 2048             # samples per spectrum: 43 ms at 48 kHz
TOP_HZ = 8000          # the spectrogram's top row
FLOOR_DB, CEILING_DB = -100.0, -20.0
PLAY_PEAK, MAX_GAIN = 0.5, 30.0  # playback raises a quiet recording's peak to half scale, by at most 30x (+30 dB)


def colormap():
    """256 colours from near-black through violet and orange to pale yellow."""
    stops = np.array([0, 0.25, 0.5, 0.75, 1.0])
    rgb = np.array([[8, 8, 24], [70, 20, 110], [190, 50, 90], [250, 150, 40], [255, 250, 200]], float)
    x = np.linspace(0, 1, 256)
    return np.stack([np.interp(x, stops, rgb[:, c]) for c in range(3)], 1).astype(np.uint8)


@lru_cache(maxsize=8)
def spectrum_grid(length, rate, rows):
    """Cache the window and frequency grid shared by every live column."""
    window = np.hanning(length)
    return window, window.sum() / 2, np.fft.rfftfreq(length, 1 / rate), np.linspace(TOP_HZ, 0, rows)


def spectrum_column(samples, rate, rows, lut):
    """One spectrogram column, top row highest: the input's level in dB, coloured."""
    window, normalization, hz, targets = spectrum_grid(len(samples), rate, rows)
    magnitude = np.abs(np.fft.rfft(samples * window)) / normalization
    level = np.interp(targets, hz, 20 * np.log10(magnitude + 1e-12))
    index = np.clip((level - FLOOR_DB) / (CEILING_DB - FLOOR_DB) * 255, 0, 255).astype(int)
    return lut[index]


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


def buttons_for(rect):
    """Four buttons in a row below the spectrogram: name -> [left top right bottom]."""
    width, height = rect[2] - rect[0], rect[3] - rect[1]
    gap = width * 0.03
    w = (width - 5 * gap) / 4
    top, bottom = rect[1] + height * 0.78, rect[1] + height * 0.88
    names = ('Record', 'Play', 'Stop', 'Quit')
    return {n: [rect[0] + gap + i * (w + gap), top, rect[0] + gap + i * (w + gap) + w, bottom]
            for i, n in enumerate(names)}


def inside(box, x, y):
    return box[0] <= x <= box[2] and box[1] <= y <= box[3]


def audio_demo(seconds=None):
    """Runs until Quit or Escape, or for `seconds` if given. Returns what happened:
    log, recorded_seconds, played_at and microphone (False if access was refused)."""
    # Any output: with Bluetooth or AirPlay the demo still works and says that its times are not measured.
    try:
        info = pm.open_audio(input=True, record_seconds=60, routes='any')
    except pm.PsychMetalError as e:
        if getattr(e, 'id', None) != 'PsychMetal:Microphone':
            raise
        print('The sound recorder needs the microphone, and access to it is off.\n' + str(e))
        return dict(log=[], recorded_seconds=None, played_at=None, microphone=False)
    rate = info['inputRate']
    note = '' if info['timed'] else f"  {info['device']} adds a delay the system cannot measure."
    try:
        w, rect, ifi = pm.open_window(None)
        try:
            return _run(w, rect, rate, seconds, note, info['device'])
        finally:
            pm.close(w)
    finally:
        pm.close_audio()


def playback_gain(samples):
    """The gain that brings a recording's peak to PLAY_PEAK, at most MAX_GAIN:
    an uncompressed microphone (iOS measurement mode has no automatic gain)
    records speech far below full scale."""
    peak = float(np.abs(samples).max()) if len(samples) else 0.0
    return (min(MAX_GAIN, PLAY_PEAK / peak) if peak > 0 else 1.0), peak


def _run(w, rect, rate, seconds, note='', output=''):
    area = safe_area(w, rect)
    width, height = area[2] - area[0], area[3] - area[1]
    margin = min(width, height) * 0.04
    view = [area[0] + margin, area[1] + margin, area[2] - margin, area[1] + height * 0.72]
    rows, columns = 256, 512
    image = np.zeros((rows, columns, 3), np.uint8)
    lut = colormap()
    texture = pm.make_texture(w, image)
    buttons = buttons_for(area)
    size = max(14, height * 0.03)
    escape = pm.kb_name('ESCAPE')
    pm.background_color(w, [18, 18, 26])

    sound = voice = recording_id = None
    recording = waiting = False
    played_at = recorded_seconds = None
    gain, peak = 1.0, 0.0
    was_down = False
    log = []
    end = pm.get_secs() + seconds if seconds else None
    touch = sys.platform == 'ios'
    fingers = {}                       # on a touch screen: finger -> (x, y) while it is down
    while end is None or pm.get_secs() < end:
        if touch:                      # a finger on a button is the mouse button held there
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
        if pm.kb_check()[2][escape] or (pressed and inside(buttons['Quit'], x, y)):
            break
        if pressed and inside(buttons['Record'], x, y):
            pm.stop_sound()
            recording_id = pm.start_recording()
            recording, log = True, log + ['record']
        elif recording and not down:
            pm.stop_recording()
            recording, waiting = False, True
        elif pressed and inside(buttons['Play'], x, y) and sound is not None:
            pm.stop_sound()
            voice = pm.play(sound, gain=gain)
            log.append('play')
        elif pressed and inside(buttons['Stop'], x, y):
            pm.stop_sound()
            log.append('stop')

        for e in pm.audio_results():
            if e['kind'] == 'recording end' and e['id'] == recording_id:
                recording = waiting = False
                samples, rate, first = pm.get_recording()
                recorded_seconds = len(samples) / rate
                if sound is not None:
                    pm.close_sound(sound)
                sound = pm.make_sound(samples[:, 0], rate) if len(samples) else None
                gain, peak = playback_gain(samples[:, 0])
            elif e['kind'] == 'sound start' and e['id'] == voice:
                played_at = e['time']
            elif e['kind'] == 'sound end' and e['id'] == voice:
                voice = None

        # The newest input as one new column on the right; older ones move left.
        samples, _, _ = pm.input_recent(FFT / rate)
        image[:, :-1] = image[:, 1:]
        image[:, -1] = spectrum_column(samples, rate, rows, lut)
        pm.update_texture(w, texture, image)
        pm.draw_texture(w, texture, None, view)
        pm.frame_rect(w, [90, 90, 110], view, 2)
        for khz in (0, 2, 4, 6, 8):
            ty = view[3] - (view[3] - view[1]) * khz * 1000 / TOP_HZ
            below = khz * 1000 == TOP_HZ                 # the top line's label inside the picture
            pm.draw_text(w, f'{khz} kHz', view[0] + 6, ty + size * 0.3 if below else ty - size * (1.2 if khz else 1.4),
                         [200, 200, 210], size * 0.7)

        level = 20 * np.log10(np.sqrt(np.mean(samples[-int(rate * 0.02):] ** 2)) + 1e-12)
        meter = np.clip((level - FLOOR_DB) / -FLOOR_DB, 0, 1)
        pm.fill_rect(w, [60, 200, 120], [view[0], view[3] + margin * 0.3, view[0] + (view[2] - view[0]) * meter,
                                          view[3] + margin * 0.6])

        for name, box in buttons.items():
            active = (name == 'Record' and recording) or (name == 'Play' and voice is not None)
            usable = name != 'Play' or sound is not None
            colour = [200, 60, 60] if (active and name == 'Record') else [60, 140, 220] if active else \
                [70, 70, 90] if usable else [40, 40, 50]
            pm.fill_rect(w, colour, box)
            pm.frame_rect(w, [150, 150, 170], box, 2)
            label = 'Hold to record' if name == 'Record' and not recording else 'Recording' if name == 'Record' else name
            fit = size
            (_, _, tw, th), _ = pm.text_bounds(w, label, fit)
            if tw > 0.88 * (box[2] - box[0]):                 # a narrow screen: smaller, to fit its button
                fit *= 0.88 * (box[2] - box[0]) / tw
                (_, _, tw, th), _ = pm.text_bounds(w, label, fit)
            pm.draw_text(w, label, (box[0] + box[2] - tw) / 2, (box[1] + box[3] - th) / 2, [240, 240, 245], fit)

        status = ('Recording...' if recording else 'Finishing the recording...' if waiting else
                  f'Recorded {recorded_seconds:.2f} s, peak {20 * np.log10(max(peak, 1e-6)):.0f} dB; '
                  f'plays {20 * np.log10(gain):+.0f} dB through {output or "the output"}.'
                  if recorded_seconds is not None else
                  'Hold Record and speak.')
        if played_at is not None:
            status += f'  Playback started at {played_at:.4f} s (GetSecs).'
        pm.draw_text(w, status + note, None, area[1] + height * 0.905, [210, 210, 220], size * 0.8, wrap_width=width * 0.92)
        pm.flip(w)
    if sound is not None:
        pm.close_sound(sound)
    return dict(log=log, recorded_seconds=recorded_seconds, played_at=played_at, microphone=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seconds', type=float, default=None, help='end after this long (default: until Quit)')
    parser.add_argument('--threaded', action='store_true')
    args = parser.parse_args()
    pm.run(audio_demo, args.seconds, threaded=args.threaded)
