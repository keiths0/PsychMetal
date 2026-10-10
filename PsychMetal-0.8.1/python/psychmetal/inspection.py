"""Bounded rendered-frame capture for the blob demo, never enabled implicitly.

Readback is synchronous and perturbs timing. These are GPU-rendered pixels,
not a recording of the physical panel. Presentation callbacks can arrive late.
"""
import math
import sys
import time
from collections import deque

import numpy as np
import psychmetal as pm


def missed_event(rows, after, ifi):
    """Return (token, message) only from completed, consecutive confirmations."""
    for i, row in enumerate(rows):
        token, status, timestamp, _ = row
        if token <= after:
            continue
        if status == 1:
            return int(token), 'Frame was reported dropped'
        if i and status == 0 and timestamp > 0 and math.isfinite(timestamp):
            previous = rows[i-1]
            if previous[0] == token-1 and previous[1] == 0 and previous[2] > 0:
                dt = timestamp - previous[2]
                if math.isfinite(dt) and dt > 1.5 * ifi:
                    return int(token), f'Confirmed interval {dt*1000:.2f} ms (expected {ifi*1000:.2f})'
    return None


class Inspector:
    def __init__(self, w, rect, ifi):
        self.w, self.ifi = w, ifi
        self.width, self.height = int(rect[2]-rect[0]), int(rect[3]-rect[1])
        count = min(8, (128 * 1024**2) // (self.width*self.height*3))
        if count < 2:
            raise ValueError('Display is too large for the 128 MiB diagnostic capture budget.')
        self.buffers = [np.empty((self.height, self.width, 3), np.uint8) for _ in range(count)]
        self.frames = deque(maxlen=count)
        self.next = 0
        self.reset()

    def reset(self):
        self.frames.clear()
        self.remaining_warmup = max(2, math.ceil(1/self.ifi))
        self.after = float('inf')

    def capture(self):
        """Called once immediately after the demo's Flip. False means Quit."""
        self.resumed = False
        pixels = self.buffers[self.next]
        pm.get_image(self.w, out=pixels)
        rows = pm.recent_frames(self.w, 32)
        if not len(rows):
            return True
        token = int(rows[-1, 0])  # Latest submitted user frame, including pending.
        self.frames.append((token, pixels))
        self.next = (self.next + 1) % len(self.buffers)
        if self.remaining_warmup:
            self.remaining_warmup -= 1
            self.after = token
            return True
        event = missed_event(rows, self.after, self.ifi)
        if event is None:
            return True
        keep_going = self.show(event, rows)
        # Inspector Flip calls must never become candidates in the next run.
        self.reset()
        self.resumed = keep_going
        return keep_going

    def show(self, event, rows):
        frames = list(self.frames)
        tokens = [token for token, _ in frames]
        hit, message = event
        selected = min(range(len(tokens)), key=lambda i: abs(tokens[i]-hit))
        exact = hit in tokens
        statuses = {int(r[0]): (int(r[1]), r[2]) for r in rows}
        width, height, w = self.width, self.height, self.w
        geometry = pm.diagnostic(w)['summary']
        scale_factor = float(geometry.get('backingScaleFactor', 1))
        insets = np.asarray(geometry.get('screenSafeAreaInsets', [0,0,0,0]), dtype=float)
        if not math.isfinite(scale_factor) or scale_factor <= 0:
            scale_factor = 1.
        if insets.shape != (4,) or not np.all(np.isfinite(insets)) or np.any(insets < 0):
            insets = np.zeros(4)
        top, left, lower, right = insets * scale_factor
        usable_width, usable_height = width-left-right, height-top-lower
        size = max(8, min(usable_width/38, usable_height/45))
        header = top + 5 * size
        bottom = height - lower - 3.2 * size
        scale = min(usable_width/self.width, (bottom-header)/self.height)
        iw, ih = self.width*scale, self.height*scale
        dst = [left+(usable_width-iw)/2, header, left+(usable_width+iw)/2, header+ih]
        labels = ['Previous', 'Next', 'Resume', 'Quit']
        buttons = [[left+i*usable_width/4, bottom, left+(i+1)*usable_width/4, height-lower] for i in range(4)]
        escape = pm.kb_name('ESCAPE')
        touch = sys.platform == 'ios'
        # Discard gestures that belonged to the running demo. Require a fresh
        # touch-down, or a released mouse button, before accepting an action.
        if touch:
            pm.touch_events(w)
        held = True
        tex = None
        drawn = None
        try:
            while True:
                if pm.kb_check()[2][escape]:
                    return False
                points = []
                if touch:
                    events, _ = pm.touch_events(w)
                    points = [(x, y) for _, _, phase, x, y in events if phase == 0]
                else:
                    x, y, pressed = pm.get_mouse(w)
                    if pressed[0] and not held:
                        points = [(x, y)]
                    held = bool(pressed[0])
                for x, y in points:
                    if bottom <= y <= height-lower and left <= x < width-right:
                        action = int(4*(x-left)/usable_width)
                        if action == 2:
                            return True
                        if action == 3:
                            return False
                        selected = max(0, min(len(frames)-1, selected + (-1 if action == 0 else 1)))
                if drawn != selected:
                    if tex is not None:
                        pm.close_texture(w, tex)
                        tex = None
                    tex = pm.make_texture(w, frames[selected][1])
                    drawn = selected
                token = tokens[selected]
                status, timestamp = statuses.get(token, (2, 0))
                state = {0:'confirmed', 1:'dropped', 2:'pending', 3:'GPU error', 4:'no drawable'}.get(status, 'unknown')
                pm.fill_rect(w, 0)
                pm.draw_texture(w, tex, dst_rect=dst, filter_mode=0)
                text = [message,
                        f'Capture {selected+1}/{len(frames)}; frame {token-hit:+d} relative to event; {state}',
                        'Rendered pixels; capture can cause missed refreshes.',
                        'Event frame retained.' if exact else 'Event frame expired; showing nearby retained frames.']
                for i, line in enumerate(text):
                    pm.draw_text(w, line, left+size/2, top+i*size*1.15, 255, size*.72)
                for label, box in zip(labels, buttons):
                    pm.fill_rect(w, 45, box)
                    pm.draw_text(w, label, box[0]+size/3, bottom+size, 255, size*.8)
                pm.flip(w)
                time.sleep(.01)
        finally:
            if tex is not None:
                pm.close_texture(w, tex)
