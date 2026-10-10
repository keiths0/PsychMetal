"""Custom GPU spiral carrier through a Gaussian aperture. Escape/three fingers exits."""
import argparse
from pathlib import Path
import psychmetal as pm


def shader_demo(seconds=20):
    w,rect,ifi=pm.open_window()
    try:
        source=Path(__file__).with_name('custom-shader-demo.metal').read_text(encoding='utf-8')
        shader=pm.create_shader(w,source)
        mask=pm.make_mask('gaussian',sigma=.4)
        side=.7*min(rect[2],rect[3]);cx,cy=rect[2]/2,rect[3]/2
        dst=[cx-side/2,cy-side/2,cx+side/2,cy+side/2]
        escape=pm.kb_name('ESCAPE');frames=0
        print('Custom Metal spiral, shared source on Mac and phone. Escape / three fingers exits.')
        for frame in range(max(1,round(seconds/ifi))):
            if pm.kb_check()[2][escape]:break
            pm.fill_rect(w,127.5)
            pm.draw_shader(w,shader,[.025,frame*ifi*3.141592653589793],dst,mask)
            pm.flip(w);frames+=1
        return dict(frames=frames)
    finally:
        pm.close(w)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=float,default=20)
    args=parser.parse_args();pm.run(shader_demo,args.seconds)
