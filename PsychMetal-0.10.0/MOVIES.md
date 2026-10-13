# Movies

PsychMetal draws movies frame by frame, each frame a texture on a refresh the
program chooses. The same calls work in MATLAB, Octave and Python; MATLAB counts
frames from 1, Python from 0.

## What it reads

Any movie the system reads: QuickTime (`.mov`), MPEG-4 (`.mp4`, `.m4v`), with
H.264, HEVC, ProRes and the other codecs macOS decodes. Decoding is the system's
(VideoToolbox, in hardware for H.264, HEVC and ProRes on Apple silicon). AVI,
Matroska and WebM files, and codecs macOS does not decode, are not read:
convert them first (QuickTime Player's Export, or `avconvert` in the Terminal).

Frames are read with `AVAssetReader`, not `AVPlayer`. The reader returns every
frame, in order, exactly once, with its own time; `AVPlayer` keeps to a clock of
its own and drops frames to keep up, which a stimulus must never do. Each decoded
frame reaches Metal through `CVMetalTextureCache`, without a copy.

## Calls

Python:

```python
movie, info = pm.open_movie(w, 'clip.mov')
times = pm.movie_frame_times(movie)                 # seconds, one per frame, from the file
pm.draw_movie_frame(w, movie, index[, src_rect, dst_rect, angle, filter_mode, global_alpha, modulate_color])
report = pm.play_movie(w, movie[, first, count, refreshes, src_rect, dst_rect, when, sound, gain])
n = pm.refreshes_per_frame(refresh_hz, frame_rate)
pm.close_movie(movie)
```

MATLAB and Octave:

```matlab
[movie, info] = PsychMetal('OpenMovie', w, 'clip.mov');
times = PsychMetal('MovieFrameTimes', movie);
PsychMetal('DrawMovieFrame', w, movie, index[, srcRect, dstRect, angle, filterMode, globalAlpha, modulateColor]);
report = PsychMetal('PlayMovie', w, movie[, struct('first', 1, 'count', [], 'refreshes', [], ...
                    'srcRect', [], 'dstRect', [], 'when', [], 'sound', 'auto', 'gain', 1)]);
n = PsychMetal('RefreshesPerFrame', refreshHz, frameRate);
PsychMetal('CloseMovie', movie);
```

`info`: `width`, `height` (as shown: a phone's portrait video is reported
upright and drawn upright), `frames`, `frameRate`, `duration` (seconds),
`constantRate`, `soundChannels` and `soundRate` (0 without sound), `codec` (four
characters: `avc1` H.264, `hvc1` HEVC, `ap4h` ProRes 4444, `apcn` ProRes 422, ...).

`draw_movie_frame` draws one frame into the frame being drawn, exactly as
`draw_texture` draws a texture, so a movie can be part of any stimulus. `src_rect`
is in the frame's pixels as shown; the default `dst_rect` is the frame at its own
size, centred.

## Timing: every frame for the same number of refreshes

`play_movie` shows each frame for the same whole number of refreshes: `refreshes`,
or by default the nearest whole number to the refresh rate over the movie's frame
rate, a half rounded up (`refreshes_per_frame`). It never drops a frame, never
shows one longer than the others, and never changes a frame's pixels. When the
rates do not divide, the movie plays at a different speed, and the report says
which:

| Movie | Display | Refreshes per frame | Plays at |
|---|---|---|---|
| 30 fps | 60 Hz | 2 | 30 fps |
| 60 fps | 120 Hz | 2 | 60 fps |
| 24 fps | 60 Hz | 3 (2.5 rounded up) | 20 fps |
| 25 fps | 60 Hz | 2 (2.4) | 30 fps |
| 30 fps | 50 Hz | 2 (1.67) | 25 fps |

There is no 3:2 pulldown: it would show frames for unequal times.

Each frame is decoded while the one before it is shown. The first frame is shown
at the refresh at or after `when` (default: as soon as it is decoded), and every
refresh goes through Flip, so the display's own report of each one is collected.
A frame the display shows late stays late; nothing is skipped to catch up.

`report`: `frames` (movie frames shown), `submitted` (refreshes), `shown` and
`late` (refreshes the display reported, and those more than half a refresh
late), `lateRefreshes`, `start` (the refresh the first frame was aimed at),
`firstPresented` (when the display reported it), `longestIntervalMs`,
`refreshes`, `rate` (frames per second as played), `sound` (the mode used),
`voice` and `cancelled`. Escape, three fingers on the phone, or `stop()` end it
early.

`movie_frame_times` gives each frame's time as the file stores it. A movie whose
frames are not evenly spaced (`constantRate` false; screen recordings often are)
still has each frame shown for the same number of refreshes: its timing in the
file is not reproduced.

## Random access

`draw_movie_frame` with the frame after the last one drawn continues decoding.
Any other frame is decoded from the nearest frame before it that can be decoded
on its own (a key frame); for H.264 and HEVC that may be many frames back, and
the draw waits for it. ProRes stores every frame as a key frame, so any frame is
as quick as the next. For stimuli that jump around in a movie, use ProRes.

## Sound

The movie's sound plays through PsychMetal's audio (open it first with
`open_audio`), scheduled with the first frame's refresh. `sound`:

- `'auto'` (default): played when the frames play at the movie's own rate,
  within 0.2 %; otherwise not, with a warning.
- `'off'`: not played.
- `'resample'`: played faster or slower to stay with the frames, and its pitch
  moves by the same ratio (24 fps at 20: 17 % slower and lower).
- `'stretch'`: played over the same time as the frames at its own pitch, with
  AVFoundation's spectral time-pitch algorithm, which alters the sound in other
  ways.

The sound is decoded once per movie, rate and mode, and held in memory, up to
half an hour. Display and audio run on separate clocks: over a long movie they
drift apart by tens of parts per million (a few milliseconds a minute). The sound
starts on the first frame; nothing corrects drift after that.

## Test movies

`make test` writes movies whose every frame carries its frame number in its
pixels (`tests/make_test_movie.mm`, with AVAssetWriter), reads each back and
checks it: ProRes 4444, H.264 (with B-frames and a key frame every 15 frames),
HEVC, a 24 fps one and one recorded sideways, in `tests/movies/`. The inventory
tests draw frames from them in and out of order and check each frame's number
in the pixels read back.

## Not yet known

Measured on a Mac or iPhone: how fast 4K and 6K HEVC and ProRes decode, and so
how high a frame rate `play_movie` keeps without late frames; whether drawing a
frame out of order in a long-GOP movie fits within a refresh. The phone app does
not yet have a movie demo (it needs a movie chosen from Photos).
