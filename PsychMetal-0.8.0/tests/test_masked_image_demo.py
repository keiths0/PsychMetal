"""Run the actual demo with scripted pointers; verify dragging and cleanup."""
from pathlib import Path
import importlib.util
import types
import sys
import numpy as np
root=Path(__file__).resolve().parents[1]
sys.modules['psychmetal']=types.ModuleType('psychmetal')
spec=importlib.util.spec_from_file_location('masked_image_demo',root/'python/masked_image_demo.py')
demo=importlib.util.module_from_spec(spec);spec.loader.exec_module(demo)

def run(phone=False,lost=False,fail=False):
    rectangles=[];closed=[];uploads=[];time=[-1/60];step=[0]
    def clock():time[0]+=1/60;return time[0]
    def mouse(w):
        k=step[0];step[0]+=1
        return [(216,210,[True]),(240,240,[True]),(300,300,[False])][min(k,2)]
    def touches(w):
        k=step[0];step[0]+=1
        if k==0:return np.empty((0,5)),0 # before trial
        if k==1:return np.array([[0,1,0,216,210]]),0
        if k==2:return np.array([[0,1,1,240,240]]),int(lost)
        if k==3:return np.array([[0,1,2,260,260]]),0
        return np.array([[0,2,1,300,300]]),0 # another finger cannot move a released panel
    def draw(w,texture,mask,**options):
        if fail:raise RuntimeError('injected draw failure')
        rectangles.append(np.array(options['dst_rect']))
    def upload(w,image):uploads.append(image);return 1
    demo.pm=types.SimpleNamespace(open_window=lambda:(1,[0,0,800,600],1/60),close=lambda w:closed.append(w),
       color_range=lambda *a:None,make_texture=upload,make_mask=lambda *a,**k:a[0],
       kb_wait=lambda *a:None,get_secs=clock,kb_check=lambda:(False,0,np.zeros(256,bool)),kb_name=lambda s:0,
       get_mouse=mouse,touch_events=touches,fill_rect=lambda *a:None,draw_masked_texture=draw,flip=lambda *a:None)
    demo.sys=types.SimpleNamespace(platform='ios' if phone else 'darwin')
    try:result=demo.masked_image_demo(.075)
    except RuntimeError:
        assert fail and closed==[1];return
    assert not fail and closed==[1] and len(uploads)==1 and uploads[0].shape==(256,256,3)
    assert len(rectangles)==result['frames']*4
    center=lambda frame:(rectangles[frame*4][:2]+rectangles[frame*4][2:])/2
    assert np.all(center(0)==[216,210])
    expected=[216,210] if lost else [260,260] if phone else [240,240]
    assert np.all(center(result['frames']-1)==expected),center(result['frames']-1)
run();run(phone=True);run(phone=True,lost=True);run(fail=True)
print('PASS: actual masked-image demo preserves drag offsets, releases mouse/finger, handles lost touches, uploads once and closes on error.')
