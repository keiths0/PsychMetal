#!/usr/bin/env python3
"""Compare texture upload/storage and macOS capture modes using reported timing.

Run outside Xcode/debuggers; no photodiode or other measurement probes are used.
This measures software/device reports, not light output or absence of tearing.
"""
import argparse
import json
import time
from pathlib import Path
import numpy as np
import psychmetal as pm


def performance_audit(size=1024, frames=120, capture_modes=(True, False)):
    if not isinstance(size, int) or not 16 <= size <= 4096:
        raise ValueError('size must be an integer 16..4096')
    if not isinstance(frames, int) or not 10 <= frames <= 240:
        raise ValueError('frames must be an integer 10..240')
    # Generation is excluded. float32 retains more precision than the float64
    # half-storage path; bandwidth/precision therefore differ and are reported.
    ramp = np.broadcast_to(np.linspace(0, 1, size, dtype=np.float32), (size, size)).copy()
    sources = {'uint8': (ramp*255).astype(np.uint8), 'float32': ramp,
               'float64': ramp.astype(np.float64)}
    cases = [('static_private', 'uint8', False), ('static_shared', 'uint8', False),
             ('update_single', 'float32', True), ('update_double', 'float64', True)]
    report = dict(environment=pm.environment_report(), size=size, frames=frames, runs=[],
                  note='Device-reported timing; no optical timing or tearing certification. Float formats differ in precision/bandwidth.')
    for capture in capture_modes:
        for name, dtype, update in cases:
            opened = time.perf_counter()
            with pm.open_window(color=0, capture_display=capture) as (w, rect, ifi):
                open_seconds = time.perf_counter()-opened
                source = sources[dtype]
                texture = pm.make_texture(w, source)
                if name == 'static_shared':
                    pm.update_texture(w, texture, source)  # full updates migrate to shared storage
                for _ in range(20):
                    pm.draw_texture(w, texture)
                    pm.flip(w)
                upload = []
                for _ in range(frames):
                    began = time.perf_counter()
                    if update:
                        pm.update_texture(w, texture, source)
                    upload.append(1000*(time.perf_counter()-began))
                    pm.draw_texture(w, texture)
                    pm.flip(w)
                diagnostic=pm.diagnostic(w)  # settle callbacks outside the measured loop
                recent = pm.recent_frames(w, frames)
                good = (recent[:,1] == 0) & (recent[:,2] > 0)
                intervals = np.diff(recent[:,2])[good[:-1] & good[1:]]
                run = dict(case=name, sourceType=dtype, captureRequested=bool(capture), captureActive=bool(diagnostic['summary']['displayCaptured']),
                           openSeconds=open_seconds, nominalHz=1/ifi,
                           confirmed=int(good.sum()), submitted=frames,
                           longAdjacentIntervals=int((intervals>1.5*ifi).sum()),
                           medianAdjacentMs=float(np.median(intervals)*1000) if intervals.size else None,
                           uploadMedianMs=float(np.median(upload)) if update else None,
                           upload99Ms=float(np.percentile(upload,99)) if update else None)
                report['runs'].append(run)
                print(f"{name}, capture={capture}: {run['confirmed']}/{frames} confirmed; "
                      f"{run['longAdjacentIntervals']} long intervals; upload median {run['uploadMedianMs']} ms")
                pm.close_texture(w, texture)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', type=int, default=1024)
    parser.add_argument('--frames', type=int, default=120)
    parser.add_argument('--output', type=Path, default=Path('psychmetal-performance.json'))
    args = parser.parse_args()
    report = pm.run(performance_audit, args.size, args.frames)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False)+'\n')
    print(f'Saved {args.output.resolve()}')


if __name__ == '__main__':
    main()
