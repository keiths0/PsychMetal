"""Exercise replay startup with a slow cold decoder and irregular timestamps.

Runs the actual demo helper with a controlled clock; does not claim codec or
physical audio/visual timing validation.
"""
import ast
from bisect import bisect_right
import math
from pathlib import Path
from types import SimpleNamespace

root = Path(__file__).resolve().parents[1]
source = (root / 'python/record_demo.py').read_text()
tree = ast.parse(source)
helper = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_replay_recording')
for hz in (60, 120, 119.98):
    for cold in (.001, .35, 2.):
        clock = [100.]
        calls = []
        def draw(w, movie, index, src, dst):
            clock[0] += cold if index == 0 else .001
            calls.append(('draw', index, clock[0]))
        def play(track, when):
            assert when > clock[0]
            calls.append(('play', when))
        def flip(w, when):
            assert clock[0] <= when, (clock[0], when)
            clock[0] = when
            calls.append(('flip', when))
            return (when,)
        pm = SimpleNamespace(fill_rect=lambda *a: None, draw_movie_frame=draw,
                             get_secs=lambda: clock[0], play=play, flip=flip,
                             next_refresh=lambda w, t: __import__('math').ceil(t*hz)/hz)
        scope = {'pm': pm, 'bisect_right': bisect_right}
        exec(compile(ast.Module(body=[helper], type_ignores=[]), str(root/'python/record_demo.py'), 'exec'), scope)
        times = [10., 10.+1/hz, 10.+.5, 10.+.5+1/hz]
        for track in (None, 4):
            clock[0] = 100.; calls.clear()
            result = scope['_replay_recording'](1, 2, times, [0, 0, 100, 100], track, 1/hz)
            assert result['frames'] == 4 and result['late'] == 0 and result['skipped'] == 0
            assert calls[0][0:2] == ('draw', 0)
            assert sum(c[0] == 'draw' and c[1] == 0 for c in calls) == 1
            flips = [c[1] for c in calls if c[0] == 'flip']
            assert abs((flips[2]-flips[0])-.5) < 1e-10
            if track is not None:
                scheduled = next(c[1] for c in calls if c[0] == 'play')
                assert scheduled == flips[0]
                assert calls[1][0] == 'play'
# Decoder throughput below the display rate must NOT stretch video playback
# to the number of frames times decode duration. Include a half-second hold.
for hz in (60, 120):
    for decode in (.025, .06):
        clock = [100.]
        displayed = []
        def draw(w, movie, index, src, dst):
            clock[0] += .35 if index == 0 else decode
            displayed.append(index)
        def flip(w, when):
            clock[0] = math.ceil(max(clock[0], when)*hz-1e-7)/hz
            return (clock[0],)
        pm = SimpleNamespace(fill_rect=lambda *a: None, draw_movie_frame=draw,
                             get_secs=lambda: clock[0], play=lambda *a: None,
                             flip=flip, next_refresh=lambda w,t: math.ceil(t*hz)/hz)
        scope = {'pm': pm, 'bisect_right': bisect_right}
        exec(compile(ast.Module(body=[helper], type_ignores=[]), str(root/'python/record_demo.py'), 'exec'), scope)
        times = [k/hz + (.5 if k>=int(1.5*hz) else 0.) for k in range(int(3*hz))]
        result = scope['_replay_recording'](1, 2, times, [0,0,100,100], 4, 1/hz)
        assert result['skipped'] > 0
        assert result['frames'] + result['skipped'] == len(times)
        assert displayed == sorted(set(displayed)) and displayed[-1] == len(times)-1
        assert abs(result['elapsed']-times[-1]) <= decode + 2/hz
        assert result['maxLateMs'] <= 1000*(decode+2/hz)
        # Negative control: the former all-frames loop accumulates >1 s drift.
        assert len(times)*decode-times[-1] > 1
# MATLAB/Octave follows the same preparation ordering and keeps its timestamp loop.
m = (root/'PsychMetalRecordDemo.m').read_text()
first = m.index("PsychMetal('DrawMovieFrame', w, movie, 1, [], box);")
start = m.index("start = PsychMetal('NextRefresh', w, PsychMetal('GetSecs') + max(.1, 6 * ifi));")
play = m.index("if ~isempty(track), PsychMetal('Play', track, start); end", start)
assert first < start < play
assert 'aim = start + times(k) - times(1);' in m
print('PASS: replay prepares A/V together, preserves held timestamps, and avoids accumulating video drift with slow decoding by counting expired preview frames; MATLAB ordering matches.')
