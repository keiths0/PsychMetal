"""Actual Python/Octave HDR demos: frame-grid comparisons and circular masks."""
from pathlib import Path
import importlib.util
import math
import shutil
import subprocess
import sys
import tempfile
import types
import numpy as np

root = Path(__file__).resolve().parents[1]
sys.modules['psychmetal'] = types.ModuleType('psychmetal')
spec = importlib.util.spec_from_file_location('hdr_demo', root/'python/hdr_demo.py')
demo = importlib.util.module_from_spec(spec); spec.loader.exec_module(demo)


def run(width, height, rate=60, target=16, adjust=False, phone=False, fail=False, escape=False, bad_grid=False):
    state = dict(time=0., queries=0, closed=False, warmup=0, measured=False)
    uploads, labels, batches = [], [], []
    class Window:
        def __enter__(self): return 1, [0, 0, width, height], 1/rate
        def __exit__(self, *args): state['closed'] = True
    def info(w):
        headroom = [3.2, 6.4, 12, 16][min(state['queries'], 3)]
        state['queries'] += 1
        return dict(enabled=True, currentHeadroom=headroom, potentialHeadroom=16, exposure=0)
    def upload(w, image):
        assert image.dtype == np.float32 and image.shape[2] == 4
        alpha = image[:, :, 3]; d = len(alpha)
        assert alpha[0, 0] == 0 and alpha[d//2, d//2] == 1
        assert np.any((alpha > 0) & (alpha < 1))
        assert np.allclose(alpha, alpha[::-1]) and np.allclose(alpha, alpha.T)
        assert np.all(image[:, :, :3] == image[0, 0, 0])
        uploads.append(float(image[0, 0, 0])); return len(uploads)
    def text(w, label, **opts):
        labels.append(label)
        assert 0 <= opts['x'] < width and 0 <= opts['y'] < height
    def draw(w, textures, **opts):
        if fail: raise RuntimeError('injected draw failure')
        boxes = np.asarray(opts['dst_rects']); assert boxes.shape == (4, 56)
        assert np.all(boxes[0] >= 0) and np.all(boxes[2] <= width)
        assert np.all(boxes[1] >= 0) and np.all(boxes[3] < height*.92)
        assert np.all(boxes[2] > boxes[0]) and np.all(boxes[3] > boxes[1])
        assert np.max(boxes[3, :49]) < np.min(boxes[1, 49:])
        batches.append(np.array(textures))
    def flip(w):
        state['time'] += 1/rate
        if not state['measured']: state['warmup'] += 1
    def grid(w): state['measured'] = True; return 0, 1/rate, 0 if bad_grid else state['warmup']
    def keys():
        k = np.zeros(256, bool); k[40] = escape
        if adjust and not phone and state['measured'] and len(batches) == 7: k[79] = True
        return False, 0, k
    def mouse(w):
        assert not phone, 'Phone must use real touch events, not mouse buttons'
        return width*.65, height*.215, [bool(adjust and len(batches) == 1), False, False]
    touch_calls = 0
    initial_half = min(range(1,math.ceil(rate/2)+1),key=lambda h:(abs(rate/(2*h)-target),-h))
    slow_frame = 2*initial_half+4*(initial_half-1)-1
    def touches(w):
        nonlocal touch_calls
        touch_calls += 1
        fast = (width*.65, height*.215); slow = (width*.2, height*.215)
        def event(finger, phase, xy): return [state['time'], finger, phase, *xy]
        if touch_calls == 1:
            return np.array([event(99,0,fast)]),0  # ignore a held calibration finger
        frame = len(batches)
        events = []
        if frame == 0: events = [event(99,2,fast)]
        if adjust:
            if frame == 1: events = [event(1,0,fast),event(1,2,fast)]  # quick tap between frames
            if frame == 2: events = [event(1,0,(0,0))]  # slide into a button while held: no press
            if frame == 3:
                events = [event(1,1,fast),event(2,0,fast),event(1,2,fast),event(2,2,fast)]
            if frame == 5: events = [event(1,0,(0,0)),event(1,3,(0,0))]  # system cancellation
            if frame == slow_frame-1:
                return np.array([event(1,0,slow),event(1,2,slow)]),1  # incomplete batch ignored
            if frame == slow_frame: events = [event(1,0,slow),event(1,2,slow)]
        return np.asarray(events,dtype=float).reshape(-1,5),0
    demo.sys = types.SimpleNamespace(platform='ios' if phone else 'darwin')
    demo.pm = types.SimpleNamespace(open_window=lambda **opts: Window(), color_range=lambda *a: None,
        hdr_info=info, make_texture=upload, get_secs=lambda: state['time'], kb_check=keys,
        fill_rect=lambda *a: None, fill_oval=lambda *a: None, get_mouse=mouse, touch_events=touches,
        draw_text=text, draw_textures=draw, flip=flip, grid_anchor=grid)
    try:
        result = demo.hdr_demo(1.2, target)
    except RuntimeError:
        assert (fail or bad_grid) and state['closed']; return
    assert state['closed']
    if escape:
        assert not batches and not uploads and result['frames'] == 0; return
    assert uploads == [.5, 1, 2, 4, 8, 12, 16]
    half = min(range(1,math.ceil(rate/2)+1),key=lambda h:(abs(rate/(2*h)-target),-h))
    assert result['halfCycleFrames'] == half and math.isclose(result['flickerHz'], rate/(2*half))
    assert result['frames'] == len(batches) and result['frames'] >= math.floor(rate*1.2)
    assert state['warmup'] == max(60, round(rate)) and state['queries'] >= 4
    assert result['requestedHz'] == target
    changes = [(round(t*rate), int(h)) for t, h, hz in result['rateHistory']]
    if adjust:
        expected_changes = [(0,half),(2*half,half-1),(2*half+4*(half-1),half)] if phone else [(0,2),(4,1),(8,2)]
        assert changes == expected_changes, changes
    else: assert changes == [(0, half)]
    for frame, batch in enumerate(batches):
        grid_values = batch[:49].reshape(7, 7)
        start_frame, hold = next((t, h) for t, h in reversed(changes) if t <= frame)
        expected = np.arange(1, 8)[:, None] if ((frame-start_frame)//hold)%2 == 0 else np.arange(1, 8)[None, :]
        assert np.all(grid_values == expected)
        assert np.array_equal(np.diag(grid_values), np.arange(1, 8))
        assert np.array_equal(batch[49:], np.arange(1, 8))
        assert np.array_equal(np.bincount(batch[:49].astype(int))[1:], np.full(7, 7))
    assert '8x *' in labels and '8x' in labels
    assert len(result['headroomHistory']) >= 4 and result['hdr']['currentHeadroom'] == 16


for dims, rate in [((1206,2622),120), ((2622,1206),120), ((6016,3384),59.94), ((750,1334),60), ((800,600),75), ((800,600),96)]:
    run(*dims, rate)
for target in [1, 10, 21, 24, 60]: run(1206,2622,target=target)
run(1206,2622,adjust=True)
run(1206,2622,adjust=True,phone=True,rate=60)
run(1206,2622,adjust=True,phone=True,rate=120)
run(2622,1206,adjust=True,phone=True,rate=120)
run(1206,2622,fail=True);run(1206,2622,escape=True);run(1206,2622,bad_grid=True)
for invalid in [0, 61, math.nan, math.inf]:
    try: demo.hdr_demo(flicker_hz=invalid)
    except ValueError: pass
    else: raise AssertionError('Invalid flicker target accepted')
print('PASS: one-finger touch taps (including down/up between frames), primary-finger ownership, slide-in rejection, cancellation, overflow recovery and 60/120 Hz cycle-boundary updates.')
print('PASS: Python adjustable HDR grid: circular antialiased patches, every pair, invariant diagonal/references/histogram, equal whole-frame holds at measured 59.94/60/75/120 Hz, live headroom, layout and cleanup.')

# The actual .m demo runs against a small display/clock stand-in. This checks
# MATLAB array ordering and frame counts as well as the Python implementation.
if shutil.which('octave'):
    mock = r'''
function varargout=PsychMetal(command,varargin)
global PM_HDR_TEST;s=PM_HDR_TEST;
switch lower(command)
case 'openwindow'
 s.closed=false;s.time=0;s.warmup=0;s.measured=false;s.queries=0;s.uploads=[];s.batches=zeros(0,56);
 varargout={1,[0 0 s.width s.height],1/s.rate};
case 'colorrange'
case 'getmouse'
 down=s.adjust&&s.measured&&size(s.batches,1)==1;varargout={s.width*.65,s.height*.215,[down false false]};
case 'filloval'
case 'kbcheck'
 k=false(1,256);if s.adjust&&s.measured&&size(s.batches,1)==7,k(80)=true;end;varargout={false,s.time,k};
case 'getsecs'
 varargout={s.time};
case 'fillrect'
case 'drawtext'
 assert(varargin{3}>=0&&varargin{3}<s.width&&varargin{4}>=0&&varargin{4}<s.height);
case 'flip'
 s.time=s.time+1/s.rate;if ~s.measured,s.warmup=s.warmup+1;end
case 'gridanchor'
 s.measured=true;varargout={[0 1/s.rate s.warmup]};
case 'maketexture'
 image=varargin{2};assert(isa(image,'single')&&size(image,3)==4);
 a=image(:,:,4);d=size(a,1);assert(a(1,1)==0&&a(ceil(d/2),ceil(d/2))==1);
 assert(any(a(:)>0&a(:)<1));assert(all(all(a==a')));
 rgb=image(:,:,1:3);assert(all(rgb(:)==image(1,1,1)));
 s.uploads(end+1)=image(1,1,1);varargout={numel(s.uploads)};
case 'hdrinfo'
 values=[3.2 6.4 12 16];s.queries=s.queries+1;
 varargout={struct('enabled',true,'currentHeadroom',values(min(s.queries,4)),'potentialHeadroom',16,'exposure',0)};
case 'drawtextures'
 handles=varargin{2};b=varargin{4};assert(isequal(size(b),[4 56]));
 assert(all(b(1,:)>=0)&all(b(2,:)>=0)&all(b(3,:)<=s.width)&all(b(4,:)<s.height*.92));
 assert(max(b(4,1:49))<min(b(2,50:56)));s.batches(end+1,:)=handles;
case 'close'
 s.closed=true;
otherwise
 error('Unexpected HDR demo call: %s',command);
end
PM_HDR_TEST=s;
end
'''
    with tempfile.TemporaryDirectory(prefix='pm-hdr-demo-') as temp:
        temp=Path(temp);(temp/'PsychMetal.m').write_text(mock)
        shutil.copy2(root/'PsychMetalHDRDemo.m',temp/'PsychMetalHDRDemo.m')
        script=r'''
global PM_HDR_TEST;
for rate=[59.94 60 75 96 120]
 for target=[1 10 16 21 24 60]
 PM_HDR_TEST=struct('width',1206,'height',2622,'rate',rate,'adjust',false);
 r=PsychMetalHDRDemo(1.2,target);s=PM_HDR_TEST;
 assert(s.closed&&isequal(s.uploads,[.5 1 2 4 8 12 16]));
 allH=ceil(rate/2):-1:1;[~,best]=min(abs(rate./(2*allH)-target));half=allH(best);assert(r.halfCycleFrames==half&&abs(r.flickerHz-rate/(2*half))<1e-10);
 assert(r.frames==size(s.batches,1)&&r.frames>=floor(rate*1.2));
 for k=1:r.frames
  g=reshape(s.batches(k,1:49),7,7)';
  if mod(floor((k-1)/half),2)==0,expected=repmat((1:7)',1,7);else,expected=repmat(1:7,7,1);end
  assert(isequal(g,expected)&&isequal(diag(g),(1:7)')&&isequal(s.batches(k,50:56),1:7));
 end
 assert(size(r.headroomHistory,1)==4&&r.hdr.currentHeadroom==16&&r.requestedHz==target);
 end
end
PM_HDR_TEST=struct('width',1206,'height',2622,'rate',60,'adjust',true);
r=PsychMetalHDRDemo(.4,16);s=PM_HDR_TEST;
assert(isequal(round(r.rateHistory(:,1)*60),[0;4;8])&&isequal(r.rateHistory(:,2),[2;1;2]));
for k=1:r.frames
 j=find(round(r.rateHistory(:,1)*60)<=k-1,1,'last');start=round(r.rateHistory(j,1)*60);hold=r.rateHistory(j,2);
 g=reshape(s.batches(k,1:49),7,7)';
 if mod(floor((k-1-start)/hold),2)==0,expected=repmat((1:7)',1,7);else,expected=repmat(1:7,7,1);end
 assert(isequal(g,expected));
end
disp('PASS: Octave HDR demo circular textures, pair ordering, controls, live headroom and equal whole-frame holds.');
'''
        (temp/'run_hdr_test.m').write_text(script)
        subprocess.run(['octave','--no-gui','--quiet','run_hdr_test.m'],cwd=temp,check=True,timeout=30)
else:
    print('Octave HDR demo fixture SKIPPED: Octave unavailable.')
