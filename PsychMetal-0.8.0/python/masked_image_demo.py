"""One still image, four GPU apertures. Hold and drag a panel; Escape/three fingers exits."""
import argparse
import sys
import numpy as np
import psychmetal as pm


def masked_image_demo(seconds=20):
    """Native image size is independent of aperture size; no CPU mask scaling."""
    w, rect, _ = pm.open_window()
    try:
        width, height = rect[2:]
        pm.color_range(w, 1)
        # Fixed colour image with fine and coarse detail; uploaded exactly once.
        y, x = np.mgrid[0:256, 0:256]
        checker = ((x//16+y//16) % 2).astype(np.float32)
        image = np.stack([x/255, y/255, .2+.6*checker], axis=-1).astype(np.float32)
        texture = pm.make_texture(w, image)
        masks = [None, pm.make_mask('gaussian', sigma=.4),
                 pm.make_mask('annulus', inner=.45, edge=.12),
                 pm.make_mask('raised_cosine', edge=.2)]
        side = .38*min(width, height)
        centers = np.array([[width*.27,height*.35], [width*.73,height*.35],
                            [width*.27,height*.65], [width*.73,height*.65]])
        active = None
        offset = np.zeros(2)
        previous = False
        finger = None
        touch = sys.platform == "ios"
        if touch: pm.touch_events(w)
        pm.kb_wait(True)
        begin = pm.get_secs()
        frames = 0
        print('Top: original / Gaussian. Bottom: annulus / raised cosine. Hold and drag any panel; Escape / three fingers exits.')
        while pm.get_secs()-begin < seconds:
            down, _, keys = pm.kb_check()
            if down and keys[pm.kb_name('ESCAPE')]:
                break
            if touch:
                events, dropped = pm.touch_events(w)
                if dropped: active = finger = None
                for _, ident, phase, x, y in events:
                    pointer = np.array([x,y])
                    if phase == 0 and finger is None:
                        finger = ident
                        for i in reversed(range(4)):
                            if np.all(np.abs(pointer-centers[i]) <= side/2):
                                active = i; offset = centers[i]-pointer; break
                    if ident == finger:
                        if phase in (1,2) and active is not None: centers[active] = pointer+offset
                        if phase in (2,3): active = finger = None
            else:
                x, y, buttons = pm.get_mouse(w)
                pointer = np.array([x,y]);held = bool(buttons[0])
                if held and not previous:
                    for i in reversed(range(4)):
                        if np.all(np.abs(pointer-centers[i]) <= side/2):
                            active = i;offset = centers[i]-pointer;break
                if not held: active = None
                if active is not None: centers[active] = pointer+offset
                previous = held
            pm.fill_rect(w, [.12,.12,.12])
            for center, mask in zip(centers, masks):
                dst = np.r_[center-side/2, center+side/2]
                pm.draw_masked_texture(w, texture, mask, dst_rect=dst)
            pm.flip(w)
            frames += 1
        return {'frames': frames}
    finally:
        pm.close(w)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=float,default=20)
    args = parser.parse_args()
    pm.run(masked_image_demo,args.seconds)
