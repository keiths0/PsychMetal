#!/usr/bin/env python3
"""Dot motion demo using draw_dots, with no OpenGL in the path.

Python port of PsychMetalDotDemo.m, itself a literal port of Psychtoolbox's
DotDemo:

    python3 dot_demo.py                # dots
    python3 dot_demo.py 1              # smiley sprites
    python3 dot_demo.py 2              # sub-pixel rectangles drawn as textures
    python3 dot_demo.py 0 2            # update the field every second refresh

The dot field parameters, annulus geometry, limited-lifetime rule, in/out
motion assignment and frame loop are as in the original, so the versions can be
run side by side. Exits on any key or mouse button, or after 3600 redraws.

With show_sprites 1 or 2 every sprite is drawn by one draw_textures call, the
counterpart of PsychDrawSprites2D. PsychMetal has no text drawing, so the
smiley is built arithmetically. The original's BlendFunction, point-size
clamping and DrawingFinished have no counterpart and need none (see the .m
file's PORTING NOTES).

Derived from Psychtoolbox-3's DotDemo.m (MIT licensed).
Original author: Keith Schneider, 12/13/04. Ported to PsychMetal 2026.

SPDX-License-Identifier: MIT
"""
import argparse
import math

import numpy as np

import psychmetal as pm


def smiley_image(sz):
    """White with an alpha mask, so the per-dot colours modulate it."""
    tx, ty = np.meshgrid(np.linspace(-1, 1, sz), np.linspace(-1, 1, sz))
    rad = np.sqrt(tx ** 2 + ty ** 2)
    face = (rad < 0.98) & (rad > 0.80)
    eyes = ((tx + 0.33) ** 2 + (ty + 0.28) ** 2 < 0.02) | ((tx - 0.33) ** 2 + (ty + 0.28) ** 2 < 0.02)
    mr = np.sqrt(tx ** 2 + (ty - 0.02) ** 2)
    mouth = (mr < 0.62) & (mr > 0.46) & (ty > 0.16)
    a = (face | eyes | mouth).astype(float)
    return np.dstack([np.ones((sz, sz))] * 3 + [a])


def dot_demo(show_sprites=0, waitframes=1):
    rng = np.random.default_rng()

    # ------------------------
    # set dot field parameters
    # ------------------------
    nframes = 3600      # number of animation frames in loop
    mon_width = 39      # horizontal dimension of viewable screen (cm)
    v_dist = 60         # viewing distance (cm)
    if show_sprites > 0:
        dot_speed = 0.07    # dot speed (deg/sec) - Take it sloooow.
        f_kill = 0.00       # Don't kill (m)any dots, so user can see better.
    else:
        dot_speed = 7       # dot speed (deg/sec)
        f_kill = 0.05       # fraction of dots to kill each frame (limited lifetime)
    ndots = 2000        # number of dots
    max_d = 15          # maximum radius of annulus (degrees)
    min_d = 1           # minimum
    dot_w = 0.1         # width of dot (deg)
    fix_r = 0.15        # radius of fixation point (deg)
    differentcolors = 1  # a different colour for each point if 1, common white if 0
    differentsizes = 2   # different sizes for each point if >= 1, one size if 0
    if differentsizes > 0:   # drawing large dots is a bit slower
        ndots = round(ndots / 5)

    # ---------------
    # open the screen
    # ---------------
    w, rect, ifi = pm.open_window(None, 0)
    tex = None
    try:
        center = np.array([(rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2])
        fps = 1 / ifi
        # WhiteIndex(w) in the original: the value a component takes at full intensity.
        white = pm.color_range(w)
        pm.hide_cursor()
        vbl = pm.flip(w)[0]      # initial flip

        # ---------------------------------------
        # initialize dot positions and velocities
        # ---------------------------------------
        ppd = math.pi * (rect[2] - rect[0]) / math.atan(mon_width / v_dist / 2) / 360   # pixels per degree
        pfs = dot_speed * ppd / fps                     # dot speed (pixels/frame)
        s = dot_w * ppd                                 # dot size (pixels)
        fix_cord = np.concatenate([center - fix_r * ppd, center + fix_r * ppd])
        rmax = max_d * ppd       # maximum radius of annulus (pixels from center)
        rmin = min_d * ppd       # minimum
        r = rmax * np.sqrt(rng.random(ndots))
        r[r < rmin] = rmin
        t = 2 * math.pi * rng.random(ndots)             # theta polar coordinate
        cs = np.column_stack([np.cos(t), np.sin(t)])
        xy = r[:, None] * cs     # dot positions in Cartesian coordinates (pixels from center)
        mdir = 2 * np.floor(rng.random(ndots) + 0.5) - 1   # motion direction (in or out) for each dot
        dr = pfs * mdir                                 # change in radius per frame (pixels)
        dxdy = dr[:, None] * cs                         # change in x and y per frame (pixels)

        # Different colours for each single dot, if requested (3xN, one column per dot):
        colvect = np.round(rng.random((3, ndots)) * 255).astype(np.uint8) if differentcolors == 1 else white
        # Different point sizes for each single dot, if requested:
        if differentsizes > 0:
            s = (1 + rng.random(ndots) * (differentsizes - 1)) * s

        if show_sprites == 1:
            tex = pm.make_texture(w, smiley_image(30))
            s = s * 0.2                                 # scale down, otherwise visual clutter ensues
            angles = (rng.random(ndots) - 0.5) * 60 + 90   # +/- 30 degrees around vertical
        if show_sprites == 2:
            img = np.zeros((30, 30, 4))                 # a white rectangle with a transparent border
            img[1:29, 1:29, :] = 1
            tex = pm.make_texture(w, img)
            s = 1
            angles = (rng.random(ndots) - 0.5) * 60 + 90

        # --------------
        # animation loop
        # --------------
        xymatrix = xy.T
        for i in range(nframes):
            if i > 0:
                pm.fill_oval(w, white, fix_cord)        # draw fixation dot (flip erases it)
                if show_sprites:
                    # PsychDrawSprites2D: one texture, a rect, angle and colour per sprite, one call.
                    px, py = xymatrix[0] + center[0], xymatrix[1] + center[1]
                    hq = np.asarray(s) / 2
                    pm.draw_textures(w, tex, None, np.vstack([px - hq, py - hq, px + hq, py + hq]), angles, 1,
                                     None, colvect if differentcolors == 1 else None)
                else:
                    pm.draw_dots(w, xymatrix, s, colvect, center)   # all dots, one instanced draw

            # Break out of animation loop if any key or mouse button is pressed:
            if pm.kb_check()[0]:
                break
            _, _, buttons = pm.get_mouse(w)
            if buttons.any():
                break

            xy = xy + dxdy      # move dots
            r = r + dr          # update polar coordinates too

            # check to see which dots have gone beyond the borders of the annuli
            r_out = np.flatnonzero((r > rmax) | (r < rmin) | (rng.random(ndots) < f_kill))   # dots to reposition
            nout = r_out.size
            if nout:
                # choose new coordinates
                r[r_out] = rmax * np.sqrt(rng.random(nout))
                r[r < rmin] = rmin
                t[r_out] = 2 * math.pi * rng.random(nout)
                # now convert the polar coordinates to Cartesian
                cs[r_out] = np.column_stack([np.cos(t[r_out]), np.sin(t[r_out])])
                xy[r_out] = r[r_out, None] * cs[r_out]
                # compute the new cartesian velocities
                dxdy[r_out] = dr[r_out, None] * cs[r_out]
            xymatrix = xy.T

            vbl = pm.flip(w, vbl + (waitframes - 0.5) * ifi)[0]
        if tex is not None:
            pm.close_texture(w, tex)
    finally:
        pm.close(w)
        pm.show_cursor()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('show_sprites', nargs='?', type=int, default=0, choices=[0, 1, 2])
    parser.add_argument('waitframes', nargs='?', type=int, default=1)
    parser.add_argument('--threaded', action='store_true', help='run as MATLAB does, on a worker thread')
    args = parser.parse_args()
    pm.run(dot_demo, args.show_sprites, args.waitframes, threaded=args.threaded)


if __name__ == '__main__':
    main()
