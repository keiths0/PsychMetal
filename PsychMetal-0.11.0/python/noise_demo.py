#!/usr/bin/env python3
"""Full-screen dynamic white noise, nothing uploaded.

Python port of PsychMetalNoiseDemo.m:

    python3 noise_demo.py                          # 20 s, cycles all four modes
    python3 noise_demo.py 20 uniform mono
    python3 noise_demo.py 20 normal colour 38
    python3 noise_demo.py 20 --cell 3 --frames-per-update 7
    python3 noise_demo.py 20 --noise-type binary

Click any mouse button to stop. A new independent value for every pixel on
every frame by default, at the full panel resolution. --cell sets cell width
in display pixels; --frames-per-update holds each pattern for an integer number
of refreshes. Coarser fields use a small GPU target and nearest-neighbour sampling. With no mode it spends a quarter of
the run in each combination of uniform/normal and mono/colour. --noise-type
selects a fixed binary (black/white), grayscale, or colored field instead.

By default, a pixel's value is a hash of its position and the frame's seed, evaluated in
the fragment shader, so each frame costs one instanced quad and four bytes of
transfer, where generating it on the CPU would take up to three refreshes and
upload tens of megabytes. Presentations remain at the display cadence; frames_per_update sets how many
presentations share each pattern. Coarse cells use a persistent GPU target.

It is still reproducible: every frame's seed is recorded, and at the end one
frame is rebuilt from its seed alone with noise_values and checked for
determinism. Storing the seeds instead of the frames is what makes reverse
correlation with this noise practical.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm


# The engine's shared hash helpers keep binary samples reproducible. Splitting
# a 24-bit seed into two 16-bit words keeps every shader parameter exact and
# within DrawShader's scalar bounds. Compile once before presentation begins.
BINARY_NOISE_SHADER = """
float4 psychmetal_main(float2 pixel, float2 uv, constant float4* parameters) {
    uint seed=uint(parameters[0].x)|(uint(parameters[0].y)<<16);
    uint2 cell=uint2(floor(uv*parameters[0].zw));
    uint value=pmHash(pmNoiseCell(seed,cell));
    float level=(value & 0x80000000u)?1.0:0.0;
    return float4(level,level,level,1);
}
"""


def noise_demo(seconds=20, dist=None, chroma=None, spread=128, cell=1, frames_per_update=1, noise_type=None):
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('seconds must be positive and finite.')
    if not math.isfinite(cell) or cell != int(cell) or not 1 <= cell <= 64:
        raise ValueError('cell must be an integer from 1 to 64 pixels.')
    if not math.isfinite(frames_per_update) or frames_per_update != int(frames_per_update) or not 1 <= frames_per_update <= 600:
        raise ValueError('frames_per_update must be an integer from 1 to 600.')
    cell, frames_per_update = int(cell), int(frames_per_update)
    if noise_type is not None:
        if noise_type not in ('binary','grayscale','colored'):
            raise ValueError('noise_type must be binary, grayscale or colored.')
        if dist is not None or chroma is not None:
            raise ValueError('Choose noise_type or dist/chroma, not both.')
        dist, chroma = ('binary','mono') if noise_type=='binary' else ('uniform','colour' if noise_type=='colored' else 'mono')
        if noise_type=='binary': spread=127.5  # full black/white regardless of spread argument
    # No mode means cycle: the point of the demo is that all four cost the same.
    cycling = dist is None and chroma is None
    if cycling:
        modes = [('uniform', 'mono'), ('normal', 'mono'), ('uniform', 'colour'), ('normal', 'colour')]
    else:
        modes = [(dist or 'uniform', chroma or 'mono')]
    # Mid-grey background: never visible here, since the noise covers the window.
    w, rect, ifi = pm.open_window(None, 128)
    try:
        pm.hide_cursor()
        total = max(1, round(seconds / ifi))
        width, height = map(int, rect[2:])
        # Coarse cells are generated into a small persistent GPU target, then
        # sampled nearest-neighbour at exactly cell display pixels per texel.
        # A fractional source crop preserves the last partial cell at the edge.
        target = w; noise_rect = rect; source_rect = None
        if cell > 1:
            noise_rect = [0, 0, math.ceil(width/cell), math.ceil(height/cell)]
            target, _ = pm.open_offscreen_window(w, 128, noise_rect)
            source_rect = [0, 0, width/cell, height/cell]
        binary_shader = pm.create_shader(w, BINARY_NOISE_SHADER) if noise_type=='binary' else None
        n_mode = len(modes)
        per_mode = max(1, math.ceil(total/frames_per_update) // n_mode)
        seeds = np.full(total, -1, dtype=np.int64)
        mode_of = np.full(total, -1)
        frames = 0
        last_label = ''
        print(f'\nFull-screen dynamic noise, {rect[2]:.0f} x {rect[3]:.0f}, spread {spread:g}.')
        print(f'{cell}-pixel cells; a new pattern every {frames_per_update} display frames.')
        if cycling:
            print(f'Cycling uniform/normal x mono/colour, {per_mode * frames_per_update * ifi:.1f} s each.')
        else:
            print(f'{modes[0][0]}, {modes[0][1]}.')
        print('Click to stop.\n')

        for k in range(total):
            _, _, buttons = pm.get_mouse(w)
            if buttons.any() or pm.kb_check()[2][40]:
                break
            frames = k + 1
            m = min(n_mode - 1, (k // frames_per_update) // per_mode)
            mode_of[k] = m
            label = f'{modes[m][0]}, {modes[m][1]}'
            if label != last_label:
                print(f'  {label}')
                last_label = label
            fresh = k % frames_per_update == 0
            if binary_shader is not None:
                if fresh: seed=int(np.random.randint(0,16777216))
                if fresh or cell==1:
                    pm.draw_shader(target,binary_shader,[seed & 65535,seed >> 16,noise_rect[2],noise_rect[3]],dst_rect=noise_rect)
            elif fresh:
                seed = pm.draw_noise(target, noise_rect, None, modes[m][0], modes[m][1], None, spread)
            elif cell == 1:
                pm.draw_noise(w, rect, seed, modes[m][0], modes[m][1], None, spread)
            seeds[k] = seed
            if cell > 1:
                pm.draw_texture(w, target, src_rect=source_rect, dst_rect=rect, filter_mode=0)
            pm.flip(w)
        d = pm.diagnostic(w)

        # Rebuild one frame from its seed alone, well after it was shown. CPU
        # work, deliberately outside the loop, which is the point being made.
        pick = max(1, round(frames * 0.5)) - 1
        rebuilt = None; rebuild_ms = 0.; stable = None
        if frames:
            dist_p, chroma_p = modes[mode_of[pick]]
            t0 = pm.get_secs()
            def rebuild(region):
                values = pm.noise_values(w, region, int(seeds[pick]), 'uniform' if dist_p=='binary' else dist_p, chroma_p, None, spread)
                return (values>=127.5).astype(np.float64)*255 if dist_p=='binary' else values
            coarse = rebuild(noise_rect)
            rebuilt = np.repeat(np.repeat(coarse, cell, axis=0), cell, axis=1)[:height, :width] if cell > 1 else coarse
            rebuild_ms = (pm.get_secs() - t0) * 1000
            corner = [0, 0, min(256, noise_rect[2]), min(256, noise_rect[3])]
            stable = np.array_equal(rebuild(corner),rebuild(corner))
    finally:
        pm.close(w)
        pm.show_cursor()

    warmup = min(120, round(frames / 3))
    st_all = pm.frame_stats(d, ifi)
    st = pm.frame_stats(d, ifi, warmup)
    seed_bytes = frames * 8
    frame_bytes = frames * (rebuilt.size if rebuilt is not None else 0) * 8
    report = dict(ifi=ifi, frames=frames, seeds=seeds[:frames], modeOf=mode_of[:frames], modes=modes,
                  spread=spread, cell=cell, framesPerUpdate=frames_per_update, noiseType=noise_type or 'legacy', achievedHz=st['achievedHz'], skipped=st['skipped'],
                  achievedHzWithSettling=st_all['achievedHz'], rebuiltFrame=pick + 1 if frames else 0, rebuildMs=rebuild_ms,
                  rebuildStable=stable, rebuiltMin=float(rebuilt.min()) if frames else None, rebuiltMax=float(rebuilt.max()) if frames else None,
                  rebuiltMean=float(rebuilt.mean()) if frames else None, seedLogBytes=seed_bytes, frameLogBytes=frame_bytes,
                  summary=d['summary'])
    print('\n===== dynamic white noise, computed in the shader =====')
    print(f"Frames {frames}; skipped {report['skipped']}")
    print(f"RATE: {report['achievedHz']:.3f} presentations/s")
    print(f"       {st_all['achievedHz']:.3f}/s if the first {warmup} settling frames are kept "
          f"(skipped {st_all['skipped']})")
    if cycling:
        print('\nPer mode:')
        for m in range(n_mode):
            rows = np.flatnonzero(mode_of[:frames] == m)
            if rows.size < 5:
                continue
            sub = pm.frame_stats(d, ifi, rows[0] + 6)
            print(f"  {modes[m][0] + ', ' + modes[m][1]:<18} {sub['achievedHz']:8.3f}/s")
        print("  (each runs from that mode's start to the end of the run, so a row\n"
              '   includes the modes after it; read them as "no mode broke the rate")')
    if frames:
        print(f'\nRECONSTRUCTION. Frame {pick + 1} rebuilt from seed {seeds[pick]} alone, {rebuild_ms:.1f} ms.')
        print(f"  repeatable: {'yes' if stable else 'NO - the generator is not deterministic'}")
        print(f"  range {report['rebuiltMin']:.4f} to {report['rebuiltMax']:.4f}, mean {report['rebuiltMean']:.4f}")
        print(f'  CPU reconstruction took {rebuild_ms:.1f} ms outside the presentation loop; playback used the GPU.')
    else:
        print('\nRECONSTRUCTION. No stimulus frames were presented.')
    print(f'\nSTORAGE. Seed log {seed_bytes / 1e3:.1f} kB against {frame_bytes / 1e6:.1f} MB for the frames '
          'themselves,')
    print(f'  a factor of {frame_bytes / max(1, seed_bytes):.0f}, and the frames are recoverable from the seeds.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('seconds', nargs='?', type=float, default=20)
    parser.add_argument('dist', nargs='?', choices=['uniform', 'normal'], default=None)
    parser.add_argument('chroma', nargs='?', choices=['mono', 'colour', 'color'], default=None)
    parser.add_argument('spread', nargs='?', type=float, default=128)
    parser.add_argument('--noise-type', choices=['binary','grayscale','colored'], help='use one noise type instead of cycling modes')
    parser.add_argument('--cell', type=int, default=1, help='noise cell width in display pixels')
    parser.add_argument('--frames-per-update', type=int, default=1, help='hold each pattern for this many display frames')
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(noise_demo, args.seconds, args.dist, args.chroma, args.spread, cell=args.cell,
           frames_per_update=args.frames_per_update, noise_type=args.noise_type, threaded=args.threaded)


if __name__ == '__main__':
    main()
