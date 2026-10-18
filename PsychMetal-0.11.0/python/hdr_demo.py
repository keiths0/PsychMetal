"""Pairwise HDR flicker grid and steady references; no nits calibration."""
import math
import sys
import numpy as np
import psychmetal as pm


def hdr_demo(seconds=20, flicker_hz=16):
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('seconds must be positive and finite.')
    if not math.isfinite(flicker_hz) or not 1 <= flicker_hz <= 60:
        raise ValueError('flicker_hz must be finite and between 1 and 60 Hz.')
    with pm.open_window(hdr=True) as (w, rect, ifi):
        pm.color_range(w, 1)
        levels = [.5, 1, 2, 4, 8, 12, 16]
        width, height = rect[2:]
        size = max(12, min(width / 45, height / 38))
        # Measure the confirmed refresh grid before choosing equal, whole-frame
        # half-cycles. Startup/calibration frames are not stimulus frames.
        for _ in range(max(60, round(1 / ifi))):
            if pm.kb_check()[2][40]:
                return dict(frames=0, hdr=pm.hdr_info(w), levels=levels,
                            headroomHistory=[], stoppedDuringCalibration=True)
            pm.fill_rect(w, 0)
            pm.draw_text(w, 'Measuring display refresh...', x=width*.08, y=height*.12,
                         size=size, wrap_width=width*.84, color=1)
            pm.flip(w)
        _, ifi, samples = pm.grid_anchor(w)
        if samples < 30 or not math.isfinite(ifi) or ifi <= 0:
            raise RuntimeError('Could not measure the display refresh rate from confirmed frames.')
        requested_hz = flicker_hz
        ideal_half = 1/(ifi*2*flicker_hz)
        candidates = {max(1, math.floor(ideal_half)), max(1, math.ceil(ideal_half))}
        half_frames = min(candidates, key=lambda h: (abs(1/(ifi*2*h)-flicker_hz), -h))
        flicker_hz = 1 / (ifi * 2 * half_frames)
        n = len(levels)
        span = min(width*.78, height*.48)
        pitch = span / n; edge = pitch*.78
        left = (width-span)/2; top = height*.27
        boxes = []
        for row in range(n):
            for column in range(n):
                x = left+(column+.5)*pitch; y = top+(row+.5)*pitch
                boxes.append([x-edge/2, y-edge/2, x+edge/2, y+edge/2])
        ref_edge = min(edge*.7, width*.8/(n*1.2), height*.065)
        for i in range(n):
            x = width/2+(i-(n-1)/2)*ref_edge*1.2; y = height*.82
            boxes.append([x-ref_edge/2, y, x+ref_edge/2, y+ref_edge])
        # Precompute circular RGBA patches once at their largest display size.
        # Straight RGB stays constant across the antialiased alpha edge.
        diameter = max(64, math.ceil(max(edge, ref_edge)))
        coordinates = np.arange(diameter, dtype=np.float32)+.5-diameter/2
        coverage = np.clip(diameter/2-.5-np.hypot(coordinates[:, None], coordinates[None, :]), 0, 1)
        image = np.empty((diameter, diameter, 4), dtype=np.float32)
        image[:, :, 3] = coverage
        textures = []
        for level in levels:
            image[:, :, :3] = level
            textures.append(pm.make_texture(w, image))
        textures = np.asarray(textures)
        # Transposed cells run in opposite phase, keeping the global histogram
        # constant. Diagonal cells sample exactly the same texture in both phases.
        indices = (np.repeat(np.arange(n), n), np.tile(np.arange(n), n))
        batches = [np.concatenate((textures[i], textures)) for i in indices]
        destinations = np.asarray(boxes, dtype=np.float64).T
        label_size = max(12, min(size, pitch*.25))
        radius = min(width, height)*.035
        centers = [(width*.2, height*.215), (width*.65, height*.215)]
        hit_boxes = [(x-radius*1.5, y-radius*1.5, x+radius*1.25+size*4, y+radius*1.5)
                     for x, y in centers]
        footer = ('Diagonal = identical levels. 1x = SDR white.\n'
                  '* Above headroom; may clip. Left/Right or tap to adjust. Escape / three fingers exits.')
        start = pm.get_secs(); next_query = start; frames = 0; history = []
        cycle_frame = 0; pending_half = half_frames
        max_half = max(1, math.floor(1/(ifi*2)+.5))
        rate_history = [[0., half_frames, flicker_hz]]
        previous_keys = np.zeros(2, dtype=bool)
        on_phone = sys.platform == 'ios'
        touch_fingers = set()
        if on_phone:
            # Drain calibration contacts without activating a button; retain
            # any fingers still held so a second finger cannot become a press.
            events, _ = pm.touch_events(w)
            for _, finger, phase, _, _ in events:
                if int(phase) == 0: touch_fingers.add(int(finger))
                elif int(phase) >= 2: touch_fingers.discard(int(finger))
        else:
            _, _, buttons = pm.get_mouse(w); was_down = bool(buttons[0])
        while pm.get_secs()-start < seconds:
            keys = pm.kb_check()[2]
            if keys[40]:
                break
            now = pm.get_secs()
            arrows = np.asarray([keys[79], keys[78]], dtype=bool)  # Left / Right
            change = int(arrows[0] and not previous_keys[0])-int(arrows[1] and not previous_keys[1])
            previous_keys = arrows
            presses = []
            if on_phone:
                events, dropped = pm.touch_events(w)
                if dropped:
                    touch_fingers.clear()  # incomplete gestures cannot activate controls
                else:
                    for _, finger, phase, x, y in events:
                        finger, phase = int(finger), int(phase)
                        if phase == 0:
                            if not touch_fingers: presses.append((x, y))
                            touch_fingers.add(finger)
                        elif phase >= 2:
                            touch_fingers.discard(finger)
            else:
                x, y, buttons = pm.get_mouse(w); down = bool(buttons[0])
                if down and not was_down: presses.append((x, y))
                was_down = down
            # Process touch downs individually: a down/up pair can arrive
            # between refreshes and must still count as one tap.
            for x, y in presses:
                for index, (l, t, r, b) in enumerate(hit_boxes):
                    if l <= x <= r and t <= y <= b:
                        change += 1 if index == 0 else -1
                        break
            pending_half = max(1, min(max_half, pending_half+change))
            # Apply changes at full-cycle boundaries so both levels keep the
            # same integer hold count, even when the user adjusts mid-cycle.
            if cycle_frame == 0 and pending_half != half_frames:
                half_frames = pending_half; flicker_hz = 1/(ifi*2*half_frames)
                rate_history.append([now-start, half_frames, flicker_hz])
                next_query = now
            if now >= next_query:
                # This is an educational comparison, not a timing benchmark.
                info = pm.hdr_info(w)
                history.append([now-start, info['currentHeadroom'], info['potentialHeadroom']])
                status = (f"Current: {info['currentHeadroom']:.2f}x | Potential: {info['potentialHeadroom']:.2f}x\n"
                          f"Frame-grid rate: {flicker_hz:.2f} Hz; {half_frames} frames per level")
                labels = [f"{v:g}x"+(' *' if v > info['currentHeadroom'] else '') for v in levels]
                next_query = now+.5
            pm.fill_rect(w, 0)
            pm.draw_text(w, 'HDR flicker comparisons', x=width*.08, y=height*.07,
                         size=size*1.2, wrap_width=width*.84, color=1)
            pm.draw_text(w, status, x=width*.08, y=height*.12,
                         size=size, wrap_width=width*.84, color=1)
            for (cx, cy), symbol, caption in zip(centers, ['-', '+'], ['Slower', 'Faster']):
                pm.fill_oval(w, .15, [cx-radius, cy-radius, cx+radius, cy+radius])
                pm.draw_text(w, symbol, x=cx-size*.45, y=cy-size*.7, size=size*1.5, color=1)
                pm.draw_text(w, caption, x=cx+radius*1.25, y=cy-size*.6, size=size, color=1)
            phase = cycle_frame // half_frames
            pm.draw_textures(w, batches[phase], dst_rects=destinations)
            for i, level in enumerate(levels):
                pm.draw_text(w, f'{level:g}x', x=left+(i+.5)*pitch-edge/2,
                             y=top-pitch*.35, size=label_size, color=1)
                pm.draw_text(w, f'{level:g}x', x=left-pitch*.65,
                             y=top+(i+.5)*pitch-label_size*.6, size=label_size, color=1)
                box = boxes[n*n+i]
                pm.draw_text(w, labels[i], x=box[0], y=box[3]+ref_edge*.06,
                             size=max(12, min(size, ref_edge/2.5)), color=1)
            pm.draw_text(w, 'Steady references', x=width*.08, y=height*.775,
                         size=size*.85, wrap_width=width*.84, color=1)
            pm.draw_text(w, footer, x=width*.08, y=height*.925,
                         size=size*.75, wrap_width=width*.84, color=1)
            pm.flip(w); frames += 1
            cycle_frame = (cycle_frame+1) % (2*half_frames)
        info = pm.hdr_info(w)
        history.append([pm.get_secs()-start, info['currentHeadroom'], info['potentialHeadroom']])
        print(f'HDR flicker: {flicker_hz:.3f} Hz on the measured frame grid; '
              f'{half_frames} frames per level. Final headroom:', info)
        return dict(frames=frames, hdr=info, levels=levels, headroomHistory=history,
                    ifi=ifi, halfCycleFrames=half_frames, flickerHz=flicker_hz,
                    requestedHz=requested_hz, rateHistory=rate_history)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('flicker_hz', nargs='?', type=float, default=16)
    options = parser.parse_args()
    pm.run(hdr_demo, seconds=options.seconds, flicker_hz=options.flicker_hz)
