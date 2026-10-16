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
half an hour or 256 MiB of decoded float PCM, whichever comes first. Leading
silence counts toward both limits and is checked before allocation. Display and audio run on separate clocks: over a long movie they
drift apart by tens of parts per million (a few milliseconds a minute). The sound
starts on the first frame; nothing corrects drift after that.

## Recording what PsychMetal draws

Two clock modes are available. `clock='live'` is the default and records the
existing live presentation path. `clock='virtual'` is an opt-in stimulus export
mode for Flip loops, queued frames and native timeline/movie playback.
[Standalone offscreen export](OFFSCREEN-EXPORT.md) uses the same renderer without
a presentation window.

```python
pm.start_movie_recording(w, 'session.mov'[, codec='prores4444', scale=1, sound=True, clock='live'])
...                                   # the program runs as usual
report = pm.stop_movie_recording(w)
```

```matlab
PsychMetal('StartMovieRecording', w, 'session.mov'[, struct('codec', 'prores4444', 'scale', 1, 'sound', true, 'clock', 'live')]);
report = PsychMetal('StopMovieRecording', w);
```

For showing what an experiment looks like, not for running one. While recording,
every frame the window presents (Flip, QueueFlip, PlayTimeline, PlayMovie)
becomes one frame of the movie, exactly as rendered: PsychMetal's frames only,
no other windows, no cursor.

**Timing.** Each frame is stamped with the refresh it was aimed at, counted from
the first recorded frame. A frame that stays on the screen for several refreshes
(the program did not flip, or flipped with a later time) lasts that long in the
movie. A frame the display showed late while recording is in the movie on time;
`report.late` says how many there were.

**Nothing is dropped.** After each frame is rendered, the GPU draws it, scaled,
into a buffer the hardware encoder reads (AVAssetWriter's pixel-buffer pool,
through CVMetalTextureCache: no CPU copy). If the encoder falls behind, the next
Flip waits for it. A live program can therefore run slower while recording, and
its frames then come late; a program that computes its stimulus from the time
Flip returns will show those delays in the movie. Recording at a smaller
`scale`, or with HEVC, lightens the load.

**Virtual clock.** Use `clock='virtual'` (MATLAB/Octave: option `clock`, value
`virtual`) to exclude time spent inside Flip waiting for presentation/encoding.
Flip returns the intended logical refresh; GetSecs returns that time plus caller
work since Flip returned. WaitSecs still waits in real time and advances the
logical clock. Explicit later Flip targets preserve held frames. Caller waits after the last
Flip are also included through Stop, rounded up to a complete refresh. The clock uses
the window's nominal refresh period. After recording ends, GetSecs returns the
ordinary physical clock again: use the recording report for its duration.

With virtual recording, open audio first and stop any existing voices. Newly
scheduled Play/Stop/Modulate commands are rendered by the same mixer on the
logical timeline, including commands whose live voices already finished. Closed
sound handles retain their samples for export. Live speaker playback can be
late/out of sync while exporting; the generated movie soundtrack is the intended
sequence. Recording does not copy microphone input unless the program explicitly
makes and plays a sound from it. The command log is bounded to 65,536 entries and
256 MiB of retained source PCM; exceeding it fails the export rather than dropping
commands. Audio opened after virtual recording starts is refused.

Virtual mode supports Flip, QueueFlip (direct presentation only), DrawMovieFrame,
PlayTimeline, PlayMovie and ordinary drawing calls.
Native timeline/movie playback advances one logical refresh per submitted frame,
excluding decoding, scene sampling and presentation-report waits. PlayMovie start
times use the logical clock; its firstPresented and timing statistics remain physical.
QueueFlip targets must increase on the logical clock. QueueResults waits do not
stretch the exported sequence; its requested/presented fields remain physical.
Queued frames are captured at submission, so QueueCancel does not remove frames
already recorded. ConfirmStartup is refused: run startup checks first.
Frame-keyed audio resolves QueueFlip tokens from this recording to logical frame
times; live sound still targets their physical projections. Schedule it immediately
after QueueFlip, before queuing later frames. Earlier offsets/older tokens work
only if their PCM interval has not yet been claimed by the writer. Requests that
would rewrite already encoded sound fail the export, preserving the previous
destination file. Tokens from other recordings or overwritten history are refused.
Physical presentation
history, input sample timestamps, live output events, confirmation flags and timing
costs remain physical diagnostics, not logical timestamps. They must not be
subtracted directly from virtual Flip/GetSecs values. This is an export facility,
not a way to hide missed frames during experiments.

**Codecs.** `prores4444` (default; visually lossless, large: a 6K window at
60 Hz is several Gbit/s to disk), `prores422`, `hevc`, `h264`. ProRes goes in
`.mov`; HEVC and H.264 in `.mov`, `.mp4` or `.m4v`. An existing file is replaced only after the new movie finishes successfully.
Recording uses a temporary file beside the destination; a failed export leaves
the previous file intact and cleans up the temporary file.
The colours are written as the window's pixel values, tagged Rec. 709.

**Sound in live-clock mode.** With audio open (`open_audio`) and `sound` true (the default),
everything PsychMetal's audio plays from the start of recording is the movie's
sound track: the output's first two channels, linear PCM in `.mov`, AAC in `.mp4`
and `.m4v`. The mixer copies each buffer it plays into a lock-free ring, with the
time it is heard; a thread of the recorder's places it on the track by that time,
against the first frame's aim. Frames and sound are on the same clock (GetSecs),
so a sound scheduled for a frame's time is on that frame in the movie. A frame
shown late while recording is on time in the movie while the sound plays as it was
heard, so the two agree exactly only when `late` is 0. Audio opened after the
recording starts is not on the track.

Waiting for the first video frame retains only a bounded recent audio backlog.
Audio callbacks acknowledge detachment before their tap is freed; encoder
readiness waits time out after 10 seconds, and finalization after 30 seconds,
rather than leaving the application waiting indefinitely. Samples lost from the
movie backlog after its first frame count toward `soundLostSeconds`.

`report`: `path`, `codec`, `width`, `height`, `frames` (movie frames written),
`refreshes` (the movie's length in refreshes), `refreshHz` (its timebase: the
display's nominal rate), `duration`, `late`, `unreported`, `sound` (whether there
is a sound track), `soundSeconds`, `soundLostSeconds` (sound that did not reach
the track; zero unless the computer was overloaded). Close while recording
finishes the file as Stop would. In-flight GPU and writer callbacks retain their
session until completion; closing admission prevents Stop from missing a frame
still allocating its encoder buffer.

**Standalone export:** see [OFFSCREEN-EXPORT.md](OFFSCREEN-EXPORT.md). Its clock
also excludes caller CPU work and advances waits without sleeping. Actual GPU/codec
acceptance remains pending.
The phone has Record a stimulus and Share recorded movie, using an app-local file.

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
frame out of order in a long-GOP movie fits within a refresh. The phone app includes bundled movie playback, recording/replay and export.
Selecting a movie from Photos is not implemented.

Sequential drawing prepares a bounded lookahead on the movie's serial worker
queue: up to eight frames by default within a 256 MiB logical pixel budget.
PrepareMovie/prepare_movie can reconfigure it or preload the whole movie.
Repeated/preloaded draws enqueue no redundant prefetch work; seeks retain exact
frame indices. Submitted GPU draws and decoder internals may retain additional
resources outside the logical pixel budget.
Movie metadata loading has a 30-second timeout.

At Stop, virtual recordings publish the final sound interval before waiting for
video encoding. Audio and video inputs signal end-of-stream independently as
their producers finish, so writer interleaving cannot wait on an EOF withheld
by the other producer's shutdown. A failure preserves any previous destination
file. Errors distinguish audio and video readiness timeouts.

Recording feeds both writer inputs as push sources, including with a virtual
clock. They use AVAssetWriter's real-time input mode to prevent ideal-interleaving
readiness from blocking video while generated audio waits for the next Flip.
This setting does not change movie timestamps or make the export clock physical.
Actual encoder backpressure still waits, with six admitted video frames at most
and bounded timeouts; frames and audio samples are not dropped.

The recording demos replay the saved file as a time-based preview. If decoding
falls behind, they skip expired preview frames to catch up with the continuous
audio timeline and report those skips, playback elapsed time and maximum delay.
Every recorded frame remains in the movie. This preview policy does not change
PlayMovie's separate all-frames playback policy; it cannot guarantee frame-perfect
preview when decode/draw work exceeds the display period.

### Buffered decode, preload and random access

Movies default to an eight-frame lookahead, reduced for large frames to fit
256 MiB of cached BGRA pixels. Playback warms that ring before scheduling sound.
Use `pm.prepare_movie(w, movie, frames=16, max_bytes=256*1024*1024)` or
`PsychMetal('PrepareMovie', movie, 16, 256*1024*1024)` to choose a different ring
(up to 256 frames). Set frames to zero to preload the entire movie for instant
random access. The complete decoded size is checked before decoding; insufficient
budgets raise an error. max_bytes may be 16 bytes to 2 GiB; the budget is for
cached pixel data, excluding decoder internals and frames retained by GPU draws.

`info.keyframeInterval` gives the largest sync-frame spacing in video frames
(1 means all-intra; 0 means unknown). To re-encode for efficient seeks without a
window, use `pm.transcode_movie(source, destination, codec='h264')` or
`n=PsychMetal('TranscodeMovie', source, destination, 'h264')`. Both return the
number of video frames. H.264/HEVC use a keyframe interval of one and no frame
reordering; ProRes is inherently intra-frame. The converter preserves decoded
video timestamps and orientation. Conversion uses 8-bit BGRA and stereo audio;
it is not an HDR, high-bit-depth or multichannel preservation tool. Audio is PCM
in .mov and AAC in .mp4/.m4v. Every video frame is retained; a previous destination
is replaced atomically only after successful finalization.

PlayMovie reports `audioStartOffsetMs`, `audioEndOffsetMs`, and
`audioVideoDriftMs` (end offset minus start offset). Positive offsets mean audio
is later. These compare Core Audio sample events with confirmed display reports;
they do not measure photons or speaker onset. Missing confirmations, no sound,
an unfinished/interrupted voice or partial playback can leave values NaN.
Video deadline misses and track padding can affect these offsets; they must not
be interpreted as pure oscillator drift. Timing observation does not drain the
program's AudioResults events.

Selected-range playback trims sound to that frame range, including its source
onset and the requested playback rate. A movie keeps one cached decoded sound
handle; changing the range/rate replaces that cache without stopping voices
that still own the previous samples. CloseAudio clears movie sound caches, so
reopening audio cannot reuse expired handles.
