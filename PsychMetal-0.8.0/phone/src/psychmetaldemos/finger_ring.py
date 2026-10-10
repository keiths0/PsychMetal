"""A ring of rectangles that turns round the pointer: the mouse on a Mac, a
finger on a phone. The dot at the pointer brightens while button 1 is down: a
click on a Mac, a second finger on a phone. It ends after a fixed time or on
Escape: three fingers on a phone.

Nothing here asks which machine it is on. Places are fractions of the window.

On a Mac:   python3 -m psychmetaldemos.finger_ring    (from the src folder)
"""
import numpy as np

import psychmetal as pm


def finger_ring(seconds=15.0):
    with pm.open_window(None, [38, 38, 51]) as (w, rect, ifi):
        width, height = float(rect[2]), float(rect[3])
        unit = min(width, height)
        radius, size = 0.25 * unit, 0.04 * unit
        angle = np.linspace(0, 2 * np.pi, 12, endpoint=False)
        colours = np.vstack([255 * (0.5 + 0.5 * np.cos(angle)), np.full(12, 64.0),
                             255 * (0.5 + 0.5 * np.sin(angle))])                    # 3 x 12, one column each
        pm.set_mouse(w, width / 2, height / 2)
        escape = pm.kb_name('ESCAPE')
        times, touches, why = [], Touches(), 'time'
        began = vbl = pm.flip(w)[0]
        while vbl - began < seconds:
            x, y, buttons = pm.get_mouse(w)
            turned = angle + 0.5 * (vbl - began)
            cx, cy = x + radius * np.cos(turned), y + radius * np.sin(turned)
            pm.fill_rect(w, colours, np.vstack([cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2]))
            pm.fill_oval(w, 255 if buttons[0] else 128, [x - size / 2, y - size / 2, x + size / 2, y + size / 2])
            pm.draw_text(w, f'{1 / ifi:.0f} Hz    {seconds - (vbl - began):.0f} s', None, 0.08 * height, 255,
                         0.035 * unit)
            vbl = pm.flip(w)[0]
            times.append(vbl)
            touches.read(w)
            if pm.kb_check()[2][escape]:
                why = 'Escape'
                break
        dropped = pm.flip_info(w)['droppedFrames']
        timing = pm.diagnostic(w)
    return report(width, height, ifi, times, dropped, touches, why, timing)


class Touches:
    """What touch_events has reported: how many events, the fingers that are down,
    and the most there have been at once."""

    def __init__(self):
        self.count, self.down, self.most = 0, set(), 0

    def read(self, w):
        """Take the events since the last call. True if a finger went down with none down."""
        events, _ = pm.touch_events(w)
        self.count += len(events)
        landed = False
        for _, finger, phase, _, _ in events:
            if phase == 0:
                landed |= not self.down
                self.down.add(finger)
            elif phase >= 2:
                self.down.discard(finger)
            self.most = max(self.most, len(self.down))
        return landed


def report(width, height, ifi, times, dropped, touches, why, timing):
    """Print what a run did, from the times its frames were shown, and return it."""
    actual = np.asarray(timing['actualTimestamp'], dtype=float)[-len(times):] if times else np.array([])
    status = np.asarray(timing['actualStatus'])[-len(times):] if times else np.array([])
    valid = (status == 0) & np.isfinite(actual)
    adjacent = valid[:-1] & valid[1:]
    intervals = np.diff(actual)[adjacent]
    confirmed = actual[valid]
    r = dict(window=f'{width:.0f} x {height:.0f} pixels', nominal_hz=1 / ifi, frames=len(times),
             seconds=float(confirmed[-1] - confirmed[0]) if len(confirmed)>1 else 0.0,
             confirmed_frames=int(valid.sum()), unconfirmed_frames=int(len(times)-valid.sum()),
             mean_hz=float(1 / intervals.mean()) if len(intervals) else float('nan'),
             longest_ms=float(1000 * intervals.max()) if len(intervals) else float('nan'),
             dropped_frames=int(dropped), touch_events=touches.count, most_fingers=touches.most, ended_by=why)
    print(f"Window: {r['window']}, nominally {r['nominal_hz']:.0f} Hz")
    print(f"{r['frames']} frames in {r['seconds']:.2f} s: {r['mean_hz']:.2f} per second")
    print(f"Longest gap between frames: {r['longest_ms']:.1f} ms")
    print(f"Frames the display reported never shown: {r['dropped_frames']}")
    print(f"Touch events: {r['touch_events']}, most fingers at once: {r['most_fingers']}")
    print(f"Ended by: {r['ended_by']}")
    return r


if __name__ == '__main__':
    pm.run(finger_ring)
