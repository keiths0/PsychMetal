# 0.10.0 remaining-wishlist implementation

These changes complete the remaining software items authorized on October 15,
excluding measurement probes. Device acceptance and performance conclusions
remain separate from implementation.

| Area | Implementation |
|---|---|
| Static textures | MakeTexture uploads through a shared staging texture into private GPU storage. Full UpdateTexture moves to reusable shared snapshots for frequent updates. Partial writes retain the original storage and wait for readers. |
| Float textures | Contiguous in-range single-precision grey/RGBA arrays are validated and uploaded without half conversion on GPUs supporting 32-bit float filtering. RGB/strided/clamped inputs are packed as float32. Older GPUs retain the half-float path. Rendering/output precision is separate from texture storage. |
| Movie buffering | Eight-frame lookahead by default, reduced to fit 256 MiB of cached pixels. PrepareMovie chooses up to 256 frames or preloads the entire movie with an explicit checked budget. Playback warms the ring before its shared A/V start. |
| Random access | OpenMovie reports maximum keyframe spacing. TranscodeMovie makes all-intra H.264/HEVC or ProRes without a window; preserves timestamps/orientation, writes transactionally, and reports the frame count. Conversion uses 8-bit BGRA and stereo audio. |
| Playback offsets | PlayMovie reports audio/display start and end offsets and their difference when confirmed display and audio-end timestamps are available. Missing evidence yields NaN. AudioResults remains available to the caller. |
| Startup | Brief AppKit event processing replaces the fixed one-second delay. Two consecutive presentation confirmations are still required, within a bounded two-second initialization. |
| Display capture | Remains enabled by default. capture_display=False / captureDisplay=false permits comparison; diagnostics report actual capture state. No claim that capture can safely be removed is made without display measurements. |
| Mac audio recovery | Interrupts stale voices/recording, retains loaded PCM and saved recording data, reopens available devices on host calls, preserves client rates, and retries failed restarts with a cooldown. Timing remains invalid after a route change. |

## APIs

```python
import psychmetal as pm
pm.open_audio()
with pm.open_window(capture_display=False) as (w, rect, ifi):
    movie, info = pm.open_movie(w, 'clip.mp4')
    pm.prepare_movie(w, movie, frames=16, max_bytes=256*1024*1024)
    pm.prepare_movie(w, movie, frames=0, max_bytes=512*1024*1024)  # full preload
    report = pm.play_movie(w, movie)
    print(report['audioStartOffsetMs'], report['audioEndOffsetMs'])
    pm.close_movie(movie)
pm.close_audio()
n = pm.transcode_movie('clip.mp4', 'clip-intra.mp4', codec='h264')
```

```matlab
PsychMetal('OpenAudio');
[w, rect, ifi] = PsychMetal('OpenWindow', struct('captureDisplay', false));
[movie, info] = PsychMetal('OpenMovie', w, 'clip.mp4');
PsychMetal('PrepareMovie', movie, 16, 256*1024*1024);
PsychMetal('PrepareMovie', movie, 0, 512*1024*1024);
report = PsychMetal('PlayMovie', w, movie);
PsychMetal('Close', w);
PsychMetal('CloseAudio');
n = PsychMetal('TranscodeMovie', 'clip.mp4', 'clip-intra.mp4', 'h264');
```

## Hardware checks when ready

The performance audit compares static private/shared textures, float uploads and
capture on/off. It records actual capture state and only uses adjacent confirmed
presentation intervals. Run outside a debugger:

```sh
python3 python/performance_audit.py --size 1024 --frames 120
```

For startup acceptance, run `PsychMetalOpenReadyTest(50)` in Octave/MATLAB.
Use the existing tear/compositor tests before deciding to remove capture by
default. Benchmark results cannot establish optical timing or prove absence of
tearing. No measurement probes were added or changed.

Mac physical-device removal/recovery, codec conversion/pixel accuracy, GPU upload
performance, 50-open startup acceptance and the refreshed phone build still need
hardware acceptance. Software test evidence is recorded in DEVELOPMENT-0.10.0.md.

Apple documents the capability used to select the direct float path:
[supports32BitFloatFiltering](https://developer.apple.com/documentation/metal/mtldevice/supports32bitfloatfiltering).
