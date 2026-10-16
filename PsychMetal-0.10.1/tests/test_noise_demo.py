"""Noise demo: frame-held seeds, GPU cell scaling, modes and immediate exit."""
from pathlib import Path
import contextlib
import importlib.util
import io
import math
import sys
import types
import numpy as np
root=Path(__file__).resolve().parents[1]
sys.modules['psychmetal']=types.ModuleType('psychmetal')
spec=importlib.util.spec_from_file_location('noise_demo',root/'python/noise_demo.py')
demo=importlib.util.module_from_spec(spec);spec.loader.exec_module(demo)


def run(cell=1,hold=1,quit=False,noise_type=None):
    width,height,total=17,11,40
    state=dict(frame=0,seed=100,closed=False,shown=False)
    draws=[];scales=[];targets=[]
    def draw(w,rect,seed,dist,chroma,mean,spread):
        if seed is None:state['seed']+=1;seed=state['seed']
        draws.append((state['frame'],w,seed,dist,chroma));return seed
    compiled=[]
    def shader(w,source):
        compiled.append(source);assert 'pmHash(pmNoiseCell' in source;return 9
    def shader_draw(w,handle,parameters,**options):
        assert handle==9 and len(parameters)==4 and max(parameters)<=1e6
        seed=int(parameters[0])+(int(parameters[1])<<16)
        assert options['dst_rect'][2:]==parameters[2:]
        draws.append((state['frame'],w,seed,'binary','mono'))
    def offscreen(w,color,rect):targets.append(rect);return 2,rect
    def texture(w,t,**options):
        assert w==1 and t==2 and options['filter_mode']==0
        assert options['dst_rect']==[0,0,width,height]
        assert options['src_rect']==[0,0,width/cell,height/cell]
        scales.append(state['frame'])
    def flip(w):state['frame']+=1
    def values(w,rect,seed,dist,chroma,*args):
        assert state['frame']==(0 if quit else total), 'CPU reconstruction ran inside the presentation loop'
        w,h=map(int,rect[2:]);a=(np.arange(w*h).reshape(h,w)+seed)%255
        return np.repeat(a[:,:,None],3,axis=2) if chroma=='colour' else a
    def keys():
        k=np.zeros(256,bool);k[40]=quit;return False,0,k
    demo.pm=types.SimpleNamespace(open_window=lambda *a:(1,[0,0,width,height],1/60),hide_cursor=lambda:None,
        open_offscreen_window=offscreen,get_mouse=lambda w:(0,0,np.zeros(3,bool)),kb_check=keys,
        draw_noise=draw,create_shader=shader,draw_shader=shader_draw,draw_texture=texture,flip=flip,diagnostic=lambda w:dict(summary={}),
        noise_values=values,get_secs=lambda:state['frame']/60,close=lambda w:state.update(closed=True),
        show_cursor=lambda:state.update(shown=True),frame_stats=lambda *a:dict(achievedHz=60,skipped=0))
    with contextlib.redirect_stdout(io.StringIO()):r=demo.noise_demo(total/60,cell=cell,frames_per_update=hold,noise_type=noise_type)
    assert state['closed'] and state['shown']
    assert len(compiled)==(1 if noise_type=='binary' else 0)
    if noise_type=='binary' and not quit:
        assert r['rebuiltMin'] in (0,255) and r['rebuiltMax'] in (0,255) and r['spread']==127.5
    if noise_type is not None:
        assert r['noiseType']==noise_type
        assert r['modes']==[('binary','mono') if noise_type=='binary' else ('uniform','colour' if noise_type=='colored' else 'mono')]
    if quit:assert not draws and r['frames']==0 and r['rebuiltFrame']==0;return
    assert r['frames']==total and r['cell']==cell and r['framesPerUpdate']==hold and r['rebuildStable']
    for k in range(0,total,hold):
        assert np.unique(r['seeds'][k:k+hold]).size==1
        assert np.unique(r['modeOf'][k:k+hold]).size==1
    assert len(np.unique(r['seeds']))==math.ceil(total/hold)
    assert len(draws)==(total if cell==1 else math.ceil(total/hold))
    assert len(scales)==(total if cell>1 else 0)
    assert targets==([[0,0,math.ceil(width/cell),math.ceil(height/cell)]] if cell>1 else [])
    assert {x[1] for x in draws}==({2} if cell>1 else {1})


for cell in (1,3,5):
    for hold in (1,3,7,60):run(cell,hold)
for kind in ('binary','grayscale','colored'):
    for cell in (1,3,5):run(cell,3,noise_type=kind)
run(3,7,quit=True)
for options in ({'cell':0},{'cell':1.5},{'frames_per_update':0},{'frames_per_update':2.5},{'noise_type':'invalid'},{'noise_type':'binary','dist':'uniform'}):
    try:demo.noise_demo(**options)
    except ValueError:pass
    else:raise AssertionError('Invalid noise controls accepted')
print('PASS: noise cell size uses exact GPU nearest scaling/cropping, held seeds and modes change only at update boundaries; cleanup and zero-frame exit.')
