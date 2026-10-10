"""Is the ring in noise_annulus drawn as it should be? Three frames are read back
from the GPU: the background alone (A), the ring's noise alone and unmasked (B),
and the two together through the ring's mask (C), as noise_annulus draws them.
If the ring is right, every pixel of C inside the ring is B's and every pixel
outside it is A's. The report counts the pixels that are neither.

The frames are what the GPU rendered, read before they are shown: this says
nothing about what the display then does with them.
"""
import numpy as np

import psychmetal as pm


def ring_check():
    with pm.open_window(readback=True) as (w, rect, ifi):
        width, height = float(rect[2]), float(rect[3])
        half = round(min(width, height) / 4)
        cx, cy = round(width / 2), round(height / 2)
        dst = [cx - half, cy - half, cx + half, cy + half]
        background = pm.make_stimulus('noise', seed=13)
        noise = pm.make_stimulus('noise', seed=37)
        y, x = np.mgrid[:2 * half, :2 * half] + 0.5 - half
        r = np.sqrt(x * x + y * y) / half
        ring = (r >= .55) & (r <= 1)
        mask = pm.make_texture(w, ring.astype(np.float32))

        def frame(*draws):
            pm.fill_rect(w, [0, 0, 0])
            for stimulus, where, through in draws:
                pm.draw_stimulus(w, stimulus, where, through, phase=-90, orientation=30)
            pm.flip(w)
            return pm.get_image(w, dst)[:, :, 0].astype(int)

        a = frame((background, rect, None))
        b = frame((noise, dst, None))
        c = frame((background, rect, None), (noise, dst, mask))
    is_a, is_b = c == a, c == b
    wrong_in, wrong_out = ring & ~is_b, ~ring & ~is_a
    edge = np.minimum(abs(r - 1), abs(r - .55)) * half           # pixels from the nearer edge of the ring
    lines = [f'Window {width:.0f} x {height:.0f}, ring {2 * half} pixels across, {ring.sum()} pixels in it',
             f'SD of the background {a.std():.1f}, of the ring\'s noise {b.std():.1f} (73.6 is right for both)',
             f'In the ring: {100 * (ring & is_b).sum() / ring.sum():.3f}% are the ring\'s noise, '
             f'{wrong_in.sum()} pixels are not',
             f'Outside it: {100 * (~ring & is_a).sum() / (~ring).sum():.3f}% are the background, '
             f'{wrong_out.sum()} pixels are not']
    for name, wrong in (('in the ring', wrong_in), ('outside it', wrong_out)):
        if wrong.any():
            share = (c[wrong] - a[wrong]) / np.where(b[wrong] == a[wrong], np.nan, b[wrong] - a[wrong])
            lines.append(f'The wrong pixels {name}: up to {edge[wrong].max():.1f} pixels from an edge, '
                         f'{100 * (edge[wrong] < 1.5).mean():.0f}% within 1.5; '
                         f'share of the ring\'s noise in them {np.nanmedian(share):.3f} (median), '
                         f'mean value {c[wrong].mean():.1f}')
    if not wrong_in.any() and not wrong_out.any():
        lines.append('Every pixel is one image or the other: the ring is drawn exactly.')
    print('\n'.join(lines))
    return dict(wrong_in_the_ring=int(wrong_in.sum()), wrong_outside=int(wrong_out.sum()))


if __name__ == '__main__':
    pm.run(ring_check)
