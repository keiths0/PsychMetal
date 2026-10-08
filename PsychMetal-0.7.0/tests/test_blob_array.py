"""Waveform, layout, drag and full Mac/iOS input-loop checks with a mock engine."""
import os
from unittest.mock import patch
import numpy as np
import psychmetal as pm
import blob_array_demo as demo

for rate, expected in [(60, [30,15,7.5,3.75,1.875,.9375]), (120,[60,30,15,7.5,3.75,1.875,.9375])]:
    hz=demo.frequencies(1/rate)
    np.testing.assert_allclose(hz, expected)
    np.testing.assert_allclose(np.cos(2*np.pi*hz[0]*np.arange(8)/rate), [1,-1]*4)
for width,height in [(600,1200),(1200,600)]:
    centers,half,size=demo.layout(width,height,7)
    assert np.all(centers[:,0]-half>=0) and np.all(centers[:,0]+half<=width)
    assert np.all(centers[:,1]-half>=0) and np.all(centers[:,1]+half+size*1.5<=height)
d=demo.Drag(np.array([[10.,10.],[10.,10.]]),5)
d.down(4,12,10); assert d.active==1
# Ignore other fingers, preserve offset, allow dragging outside the original hit area.
d.down(5,10,10); d.move(5,30,30); np.testing.assert_equal(d.centers[1],[10,10])
d.move(4,42,40); np.testing.assert_equal(d.centers[1],[40,40])
d.up(5); assert d.active==1
d.up(4); d.move(4,99,99); np.testing.assert_equal(d.centers[1],[40,40])
d.down(1,90,90); d.move(1,10,10); assert d.active is None
d.up(1); d.down(1,10,10); assert d.active==0 and d.order[-1]==0

os.environ['PM_MOCK_DISPLAY']='800x600@60'
os.environ['PM_MOCK_MOUSE']='-1,0,0'
initial,half,size=demo.layout(800,600,6)
x,y=initial[0]
mouse=iter([(x,y,[True,False,False]),(x+30,y+20,[True,False,False]),
            (x+35,y+25,[False,False,False]),(x+90,y+90,[False,False,False])])
with patch.object(pm,'get_mouse',side_effect=lambda w: next(mouse)), patch.object(demo.sys,'platform','darwin'):
    r=pm.run(demo.blob_array_demo,4/60)
np.testing.assert_allclose(r['centers'][0],initial[0]+[35,25]); assert r['frames']==4
# Actual demo loop receives ordered finger events, including another finger and cancellation.
events=iter([([[0,7,0,x,y]],0),([[0,8,0,x,y],[0,8,1,x+99,y+99],[0,7,1,x+30,y+20]],0),
             ([[0,7,3,x+30,y+20]],0),([[0,7,1,x+90,y+90]],0)])
with patch.object(pm,'touch_events',side_effect=lambda w: next(events)), patch.object(demo.sys,'platform','ios'):
    r=pm.run(demo.blob_array_demo,4/60)
np.testing.assert_allclose(r['centers'][0],initial[0]+[30,20])
assert pm._S is None
print('PASS: blob frequencies, Nyquist samples, portrait/landscape layout, mouse and finger dragging.')
