"""Miss detection, captured-pixel identity, controls, and resume isolation."""
import os
from unittest.mock import patch
import numpy as np
import psychmetal as pm
from psychmetal.inspection import Inspector, missed_event

ifi=1/120
rows=np.array([[1,0,1,0],[2,0,1+2*ifi,0]],float)
assert missed_event(rows,0,ifi)[0]==2
assert missed_event(rows,2,ifi) is None
for status in (1,2,3,4):
    unknown=rows.copy(); unknown[0,1]=status
    # No inferred interval across an unknown/unpresented predecessor.
    assert missed_event(unknown,1,ifi) is None
broken=rows.copy(); broken[1,0]=3
assert missed_event(broken,0,ifi) is None
pending=rows.copy(); pending[1,1]=2
assert missed_event(pending,0,ifi) is None
assert missed_event([[1,1,0,0]],0,ifi)[0]==1
invalid=rows.copy(); invalid[1,2]=float('nan')
assert missed_event(invalid,0,ifi) is None

ins=Inspector(1,[0,0,120,240],ifi)
ins.remaining_warmup=0;ins.after=0
seen=[]; index=[0]
def read(w,out):
    index[0]+=1; out.fill(index[0]); return out
histories=[np.array([[1,0,1,0]]), np.array([[1,0,1,0],[2,2,0,0]]),
           np.array([[1,0,1,0],[2,0,1+2*ifi,0],[3,2,0,0]])]
def show(event,history):
    assert event[0]==2
    assert [x[0] for x in ins.frames]==[1,2,3]
    assert [int(x[1][0,0,0]) for x in ins.frames]==[1,2,3]
    seen.append(event); return True
with patch.object(pm,'get_image',side_effect=read), patch.object(pm,'recent_frames',side_effect=histories), patch.object(ins,'show',side_effect=show):
    assert ins.capture() and ins.capture() and ins.capture()
assert len(seen)==1 and not ins.frames and ins.remaining_warmup==120
# Ring overwrites only the oldest frame; snapshots never alias another slot.
ins.remaining_warmup=0; ins.after=0; index[0]=0
with patch.object(pm,'get_image',side_effect=read), patch.object(pm,'recent_frames',side_effect=lambda *a:np.array([[index[0],0,index[0]*ifi,0]])):
    for _ in range(20): assert ins.capture()
assert len(ins.frames)==8
assert [int(p[0,0,0]) for _,p in ins.frames]==list(range(13,21))

# Mouse and phone controls show captured textures, then Next/Previous/Resume.
for phone in (False,True):
    ins.frames.clear()
    ins.frames.extend([(1,np.full((240,120,3),10,np.uint8)),(2,np.full((240,120,3),20,np.uint8))])
    actions=iter([[],[(45,239)],[(15,239)],[(75,239)]])
    displayed=[]
    def mouse(w):
        # Each click separated by a release.
        return next(mouse_states)
    mouse_states=iter([(0,0,[False]),(45,239,[True]),(0,0,[False]),(15,239,[True]),(0,0,[False]),(75,239,[True])])
    touch_states=iter([(np.empty((0,5)),0),(np.empty((0,5)),0),
                       (np.array([[0,1,0,45,239]]),0),(np.array([[0,1,0,15,239]]),0),(np.array([[0,1,0,75,239]]),0)])
    from contextlib import ExitStack
    with ExitStack() as stack:
        stack.enter_context(patch('psychmetal.inspection.sys.platform','ios' if phone else 'darwin'))
        for name in ('fill_rect','draw_texture','draw_text','flip','wait_secs','close_texture'):
            stack.enter_context(patch.object(pm,name))
        stack.enter_context(patch.object(pm,'diagnostic',return_value={'summary':{}}))
        stack.enter_context(patch('psychmetal.inspection.time.sleep'))
        stack.enter_context(patch.object(pm,'kb_name',return_value=0))
        stack.enter_context(patch.object(pm,'kb_check',return_value=(False,0,[False])))
        stack.enter_context(patch.object(pm,'get_mouse',side_effect=mouse))
        stack.enter_context(patch.object(pm,'touch_events',side_effect=lambda w:next(touch_states)))
        stack.enter_context(patch.object(pm,'make_texture',side_effect=lambda w,p:displayed.append(int(p[0,0,0])) or len(displayed)))
        assert ins.show((1,'Test missed frame'),np.array([[1,0,1,0],[2,0,1+ifi,0]]))
    assert displayed==[10,20,10],displayed

# Real Python/native mock boundary: bounded rows, validation and no full diagnostic.
os.environ['PM_MOCK_DISPLAY']='120x240@120'
def native():
    w,_,_=pm.open_window(None)
    try:
        for _ in range(4): pm.flip(w)
        recent=pm.recent_frames(w,2)
        assert recent.shape==(2,4) and recent[1,0]==recent[0,0]+1
        for count in (0,257,-1,1.5,True):
            try: pm.recent_frames(w,count)
            except ValueError: pass
            else: raise AssertionError(count)
    finally: pm.close(w)
pm.run(native)
print('PASS: confirmed-only missed intervals, delayed callbacks, bounded pixel ring, resume reset, phone/mouse inspection and recent-frame API.')
