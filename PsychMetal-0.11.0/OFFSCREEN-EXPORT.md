# Standalone Metal movie export (0.10.0)

Create a movie without opening a fullscreen window, capturing a display, or
requesting display drawables. This uses the same Metal stimulus/shader pipelines
and movie writer as windowed experiments. A Metal GPU and a working encoder are
still required. Broader GPU/codec acceptance remains pending; the user functionally checked the phone export demo.

Python:

```python
import psychmetal as pm

with pm.open_export(640, 480, refresh_hz=60, color=127) as (w, rect, ifi):
    pm.start_movie_recording(w, 'stimulus.mp4', codec='h264',
                            sound=False, clock='virtual')
    for frame in range(180):
        pm.draw_gabor(w, None, [160, 80, 480, 400], .5, .04, 30, frame * 6)
        pm.flip(w)
    report = pm.stop_movie_recording(w)
```

MATLAB/Octave:

```matlab
[w, rect, ifi] = PsychMetal('OpenWindow', struct( ...
    'exportSize', [640 480], 'refreshHz', 60, 'backgroundColor', 127));
try
    PsychMetal('StartMovieRecording', w, 'stimulus.mp4', struct( ...
        'codec', 'h264', 'sound', false, 'clock', 'virtual'));
    for frame = 0:179
        PsychMetal('DrawGabor', w, [], [160 80 480 400], .5, .04, 30, frame * 6);
        PsychMetal('Flip', w);
    end
    report = PsychMetal('StopMovieRecording', w);
    PsychMetal('Close', w);
catch e
    PsychMetal('Close', w);
    rethrow(e);
end
```

Ready-made examples: `python/export_demo.py` and `PsychMetalExportDemo.m`.

The rate is a nominal movie timebase, independent of connected displays. A Flip
advances at least one refresh after the preceding frame. Explicit later Flip
times preserve holds. GetSecs returns the logical timeline while recording;
WaitSecs advances that timeline without sleeping. CPU preparation, decoding,
GPU execution and encoding do not advance it. Use frame counts to choose stimulus
phases. After Stop/Close, GetSecs returns the ordinary physical clock again.

Unlike an export canvas, virtual recording of a **presentation window** preserves
caller work and real WaitSecs delays; only Flip/queue/native-playback overhead
is excluded there. See MOVIES.md for these clock modes.

The canvas supports ordinary drawing, textures, masks, custom shaders, native
movie/timeline playback, and optional GetImage readback (`readback=True` in
Python; option `readback`, true in MATLAB/Octave). Flip requires an active
virtual recording. QueueFlip and display startup checks do not apply. Flip never
claims a confirmed physical presentation; presentation statistics are not export
validation. Generated sound uses the existing virtual mixer; open audio before
recording. Its live speaker output is not synchronized to a faster-than-real-time
export. Microphone/voice-key timing is not virtualized.

Dimensions must be integers from 2 to 8192 and at most 16,777,216 pixels total.
Output is eight-bit colour. Codec scaling/even-size rules still apply. GPU waits
are bounded to 20 seconds; a failed GPU session must be closed and reopened.
Writer/command limits and atomic destination replacement are unchanged.

On iPhone/iPad, run on the app's worker thread, keep the app in front and use a
writable app-data destination. Export does not replace the app window. Leaving
the foreground stops further GPU submissions; close and reopen the canvas.
The idle timer is disabled during export and its previous setting restored on
close. The user functionally checked the iPhone export demo; broader device/codec validation remains pending.
