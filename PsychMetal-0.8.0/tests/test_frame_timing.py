"""Synthetic known intervals/drops, warm-up alignment and the full mock demo."""
import os
from unittest.mock import patch
import numpy as np
import psychmetal as pm
from psychmetaldemos.frame_timing import summarize, render_report, frame_timing

ifi=1/120
# two warmup frames, then intervals 1x, 2x, unknown, unknown, 1x.
times=10+np.array([0,1,2,3,5,6,7,8])*ifi
status=np.array([0,0,0,0,0,1,0,0])
times[5]=np.nan
d=dict(actualTimestamp=times,actualStatus=status,flipNumber=np.arange(15,23))
r=summarize('known <data>',ifi,d,[(1,2,3)]*8,2)
assert r['submitted']==6 and r['confirmed']==5 and r['unconfirmed']==1 and r['long_count']==1
np.testing.assert_allclose(r['intervals'][[1,2,5]],np.array([1,2,1])*ifi*1000)
assert np.isnan(r['intervals'][[0,3,4]]).all()
assert r['stages']['Drawing calls']['median']==2
assert np.isnan(r['stages']['GPU execution']['median'])
assert abs(r['rate']-80)<1e-6 # confirmed frames, including the gap across missing timestamp
out=render_report([r],True)
assert 'known &lt;data&gt;' in out and '<svg' in out and 'partial' in out and '1 long intervals' in out
assert 'src=' not in out and '<script' not in out
# History suffix maps to the correct CPU samples.
tail={k:v[4:] for k,v in d.items()}
r=summarize('tail',ifi,tail,[(i,i+1,i+2) for i in range(8)],2)
assert r['missing']==2 and r['stages']['Input polling']['median']==5.5
# Empty / early exit / all unknown cannot invent perfect timing.
empty={k:v[:0] for k,v in d.items()}
r=summarize('empty',ifi,empty,[],120)
assert r['submitted']==0 and np.isnan(r['rate']) and 'n/a' in render_report([r],True)
unknown=dict(d, actualStatus=np.ones(8))
r=summarize('unknown',ifi,unknown,[(1,2,3)]*8,0)
assert np.isnan(r['intervals']).all() and r['confirmed']==0
# Repeated / reversed timestamps don't count as valid intervals.
bad=dict(d,actualTimestamp=np.array([1,2,2,1,3,4,5,6.]),actualStatus=np.zeros(8))
r=summarize('bad',ifi,bad,[(1,2,3)]*8,0)
assert np.isnan(r['intervals'][2:4]).all()
# Periodically delayed presentations: known recurrence, no inferred causality.
x=np.arange(20); periods=np.ones(20); periods[::4]=2
regular=dict(actualTimestamp=10+np.cumsum(periods)*ifi,actualStatus=np.zeros(20),flipNumber=x)
r=summarize('periodic',ifi,regular,[(0,0,0)]*20,0)
assert r['long_count']==4 and abs(r['spacing']['median']-5*ifi)<1e-8
assert 'does not establish periodicity' in render_report([r])

os.environ['PM_MOCK_DISPLAY']='800x600@120'
os.environ['PM_MOCK_MOUSE']='-1,0,0'
for platform in ('darwin','ios'):
    with patch('psychmetaldemos.frame_timing.sys.platform',platform):
        result=pm.run(frame_timing,.05)
    assert len(result['conditions'])==3 and not result['stopped']
    assert all(r['submitted']==6 and r['warmup']==120 for r in result['conditions'])
    assert result['report_html'].count('<svg')==3 and pm._S is None
os.environ['PM_MOCK_KEYS']='41:0-10000' # HID Escape: early stop still returns a report.
r=pm.run(frame_timing,.05)
assert r['stopped'] and len(r['conditions'])==1 and 'partial' in r['report_html']
os.environ.pop('PM_MOCK_KEYS')
print('PASS: timing report, no bridging unknown frames, history alignment, recurrence, empty/partial data and Mac/iOS loops.')

# Portrait island and landscape side cutouts: all initial labels fit the safe area.
from psychmetaldemos.frame_timing import timing_layout
for width,height,insets in [(1206,2622,[62,0,34,0]),(2622,1206,[0,62,21,62])]:
    centers,half,size,safe,title_size=timing_layout(width,height,7,dict(backingScaleFactor=3,screenSafeAreaInsets=insets))
    assert safe[1]>=insets[0]*3+48 and safe[3]<=height-insets[2]*3-48
    assert np.all(centers[:,0]-half>=safe[0]) and np.all(centers[:,0]+half<=safe[2])
    assert np.all(centers[:,1]-half>=safe[1]+3*title_size)
    assert np.all(centers[:,1]+half+2*size<=safe[3])
print('PASS: timing layout respects portrait island, landscape cutouts and bottom safe area.')

# Event detail retains the exact CPU/history alignment across warm-up and suffixes.
windows=np.column_stack((100+np.arange(8)*.01,100+np.arange(8)*.01+.009))
spans=[(100.043,100.045,0),(100.075,100.076,2)]
event_summary=summarize('event',ifi,d,[(i,2*i,3*i) for i in range(8)],2,
                        cpu_windows=windows,gc_spans=spans)
assert len(event_summary['events'])==1
entry=event_summary['events'][0]
assert entry['frame']==3 and entry['work_ms']==[9.,12.]
assert entry['collections']==[dict(generation=0,ms=1000*(100.045-100.043))]
np.testing.assert_allclose(entry['elapsed'],3*ifi)
np.testing.assert_allclose(entry['phase_ms'],3*ifi*1000)
assert 'Each long interval' in render_report([event_summary])
# A retained history suffix continues to pick the matching CPU frames.
short={k:v[3:] for k,v in d.items()}
short_report=summarize('suffix',ifi,short,[(i,2*i,3*i) for i in range(8)],2,
                       cpu_windows=windows,gc_spans=spans)
assert short_report['events'][0]['work_ms']==[9.,12.]

from psychmetaldemos.frame_timing import GCMonitor
import gc
before=list(gc.callbacks)
monitor=GCMonitor()
try:
    with monitor:
        with patch('psychmetaldemos.frame_timing.time.perf_counter',side_effect=[10.,10.002]):
            monitor.record('start',dict(generation=1))
            monitor.record('stop',dict(generation=1))
        raise RuntimeError('test cleanup')
except RuntimeError:
    pass
assert gc.callbacks==before
assert monitor.spans()==[(10.,10.002,1)]
monitor.count=len(monitor.rows)
monitor.record('start',dict(generation=0))
assert monitor.lost==1
print('PASS: long-event timing, suffix alignment, GC overlap, bounded recording and cleanup on error.')

with patch.dict(os.environ,{'PM_MOCK_DISPLAY_LINK_DEFAULT':'1'}):
    phone_default=pm.run(frame_timing,.05,condition_indices=(1,))
assert phone_default['conditions'][0]['name'].startswith('displaylink:')
print('PASS: ordinary phone timing uses the native platform default and reports the selected backend.')
