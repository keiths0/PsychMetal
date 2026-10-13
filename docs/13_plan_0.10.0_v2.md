# PsychMetal 0.10.0: plan

October 13, 2026. Version 2: your answers on names, frame rates and the phone
menu are in; LinkInfo is still open. Everything on the list from the 0.9.0 release, with
video defined as: frame-accurate movie playback, its sound played through
PsychMetal's audio, and recording what PsychMetal draws to a movie file
(ProRes 4444 by default, HEVC or H.264 when size matters). No measuring hardware
is on hand yet; what to get is at the end.

This is a plan to review before any code is written. Each part says what it
will do, which Apple interfaces it uses, how it will be tested, and what remains
unknown until it runs on a device.

## 1. Movie playback, frame-accurate

**What it is.** A movie is opened once, and each of its frames is drawn on a
refresh the program chooses, like any texture. Nothing is dropped or repeated
behind the program's back, and every frame shown is reported with its movie
frame number and the time the display reported showing it.

**Commands**, named as the rest of PsychMetal is: a subcommand of `PsychMetal`
in MATLAB and Octave (`PsychMetal('OpenMovie', w, path)`), a function in Python
(`pm.open_movie(w, path)`), verb first as the audio commands are (`OpenAudio`,
`MakeSound`, `Play`). One entry point keeps one help system, one MEX file and
one argument checker; a separate `PsychMetalMovie` function would split them.

    movie, info = pm.open_movie(w, path)        # width, height, frames, frame rate, duration, sound
    pm.draw_movie_frame(w, movie, index[, dst_rect, src_rect, angle, alpha])
    report = pm.play_movie(w, movie[, first, last, refreshes_per_frame, when])
    pm.close_movie(movie)

`draw_movie_frame` is the building block: frame `index`, drawn into this frame
like `draw_texture`, so a movie can sit inside any other stimulus. `play_movie`
is the common case: the frames queued one per `refreshes_per_frame` refreshes
from `when`, with the sound started on the sample that belongs with the first
frame, and a report of what was shown when.

**Decoding.** `AVAssetReader` with an `AVAssetReaderTrackOutput`, not `AVPlayer`.
The reader hands over frames in order, each exactly once, with its own
presentation time; `AVPlayer` follows its own clock and is built to drop frames to
keep up, which is the opposite of what is wanted here. The reader's pixel
buffers are IOSurface-backed and become Metal textures through
`CVMetalTextureCache` without a copy. Decoding is VideoToolbox's hardware
decoder, ahead of the frames being drawn, on a thread of its own, into a ring of
decoded frames; a frame drawn from the ring costs what a texture costs.

**Colour.** Two choices, to decide by measuring:
- Ask the decoder for BGRA. VideoToolbox converts on the GPU using the movie's
  own colour attachments. Simplest; one texture per frame.
- Take the decoder's YCbCr (two planes) and convert in PsychMetal's shader with
  the movie's matrix and range. One less pass, and 10-bit movies stay 10-bit.

The default will be whichever converts exactly: a test movie with known pixel
values is decoded and read back, and every pixel is compared.

**Timing.** Every frame of a movie is shown for the same whole number of
refreshes, and no frame is altered, blended or skipped. That number is the
nearest whole number to the display's refresh rate divided by the movie's frame
rate, at least 1, unless `refreshes_per_frame` sets it. A movie whose rate does
not divide the refresh rate therefore plays at a slightly different speed, and
the report says which: 24 fps on 60 Hz is 2.5 refreshes per frame, a tie, which
goes to the larger number (3, playing at 20 fps) so a movie is never sped up by a
tie. 25 fps on 60 Hz plays at
30 fps; 30 fps on 120 Hz at 30 fps exactly; 60 fps on 60 Hz at 60. No pulldown:
3:2 and similar patterns show frames for unequal times, which is what you asked
to avoid. What the movie's sound does then is an open question (section 8).

Frames go out through the queued-frame path (QueueFlip and its presenter thread,
already validated), so each is aimed at its refresh and confirmed by the
display's own report. A frame that misses its refresh is shown late, never
skipped, and the report says which and by how much.

**Random access.** A movie's frames are stored as groups that can only be
decoded from their first frame. Drawing frame `index` out of order means
decoding from the group's start; `open_movie` reports how far apart these
starting frames are. For stimuli that jump around, the advice will be to encode
with every frame a starting frame (ProRes is always so), and a helper will
re-encode a movie that way.

**Memory.** The ring holds a few dozen decoded frames, not the movie. A whole
short movie can be decoded into memory up front when random access must be
instant.

**Tests.** A synthetic movie made by PsychMetal's own recorder (part 3), with
each frame carrying its number in its pixels, is played back; every frame read
back from the GPU must carry the number the report says. The scripted engine
gets a scripted movie, so the front ends are tested off a Mac as audio was.

**Unknown until run on a device:** decode throughput for 4K and 6K ProRes and
HEVC on the Mac and the iPhone, and how far ahead decoding must run.

## 2. A movie's sound

The sound track is decoded with an `AVAssetReaderAudioOutput` straight to the
audio session's sample rate (PCM, float), and becomes an ordinary PsychMetal
sound. When the frames play at a different rate from the movie's (above), the
sound cannot both keep its own rate and stay with its frames; see section 8. `play_movie` schedules it with the frame-keyed `play` that already exists
(a sound started at a set time after a queued frame's projected presentation),
so the movie's first sample plays with its first frame. Its start and end come
back in `audio_results` like any sound's.

**Limit:** sounds are held in memory (0.9.0's design). Ten minutes of 48 kHz
stereo is about 230 MB, which is fine; an hour is not. Longer movies need a
streaming voice, which 0.9.0 left out of scope. For 0.10.0: whole sound tracks
up to a stated length, and an error beyond it; streaming if it proves needed.

**Drift.** The display and the audio device run on different crystals. Over a
long movie the two drift apart by tens of parts per million (a few ms per
minute). The report will give the measured offset at the end. Correcting drift
mid-movie (resampling the sound, as players do) is possible but changes the
sound; off by default.

## 3. Recording what PsychMetal draws

**What it records.** PsychMetal's own frames, exactly as rendered, each stamped
with the time the display reported showing it. No other windows, no cursor, the
same on the Mac and the iPhone. Not the whole display (that would be
ScreenCaptureKit, Mac only, and compressed by the system).

**Commands:**

    pm.start_movie_recording(w, path[, codec='prores4444', scale=1, audio=False])
    report = pm.stop_movie_recording(w)       # frames written, frames missed, file

Codecs: `prores4444` (default; visually lossless, with alpha, large),
`prores422`, `hevc`, `h264`. `scale` records at a fraction of the window's size,
done on the GPU.

**How.** After each frame is drawn, the GPU copies it into a pixel buffer taken
from an `AVAssetWriterInputPixelBufferAdaptor`'s pool (IOSurface-backed, seen by
Metal through `CVMetalTextureCache`), scaling and converting on the way. When the
display reports the frame, the buffer goes to the writer with that time as its
presentation time. The file then records when each frame was actually shown,
including any frame shown late; a constant-rate file is an option.

**Offline recording.** The same commands on an offscreen window record without
presenting anything: a stimulus sequence rendered at its nominal rate and
written as a movie, as fast as the encoder allows. For making stimulus movies,
or documenting a paradigm, this is likely the more common use.

**Audio in the recording** (option): PsychMetal's audio output is taken from the
mixer, sample for sample, and written as the movie's sound track on the same
clock.

**Costs, stated plainly.** Recording a live session needs the drawable readable
(as readback does now), a GPU copy every frame, and the encoder running.
Encoding is in hardware: ProRes on every Apple-silicon Mac from the M2 on and on
the M1 Pro, Max and Ultra (the plain M1 encodes ProRes in software), HEVC and
H.264 on all. ProRes 4444 at 6016 x 3384 and 60 fps is roughly 4 to 5 Gbit/s to
disk, to be measured. As with readback, a recording session is not one to take timing from; the
report will say whether any frame was late, and `scale` reduces the load.

**Tests.** Record a synthetic sequence, play it back with part 1, compare frame
numbers and pixels (exactly for ProRes 4444, within a stated error for HEVC).

## 4. Measurement: the timing claims

None of this needs new engine features; it needs hardware (below) and probes.

**Display: photodiode.** A photodiode taped to a patch in the screen's corner,
read by one input of an audio interface (section 7). A probe flashes the
patch on chosen refreshes; the photodiode's rise, in the interface's samples,
gives when light came out, against PsychMetal's reported presentation time for
that frame. Result: the display's latency from reported presentation to light,
and its spread, per display and mode.

**Audio: loopback.** Output cabled to input on the same interface. A click
scheduled for time T comes back at T + output latency + input latency; the
probe compares that sum with what Core Audio reports. It cannot separate the two
latencies; the photodiode-and-microphone check does that.

**Audio-visual: photodiode and microphone together.** A flash and a click
scheduled for the same instant, the photodiode on one input and a microphone at
the speaker on the other. The difference between the two onsets is the
audio-visual asynchrony a participant would see and hear, measured on one
sample clock, independent of anything PsychMetal reports.

**Probes,** written before the hardware arrives: `probes/photodiode_v1.py`,
`probes/loopback_v1.py`, `probes/av_sync_v1.py`, each saving raw samples and a
summary, and each run with a simulated signal in the tests.

## 5. The rest

| Item | Approach | Checked by |
|---|---|---|
| Arc commands | `FillArc`, `FrameArc`, `DrawArc` (Screen's arguments), drawn analytically in the fragment shader like ovals | pixel test against the rule in double precision, as polygons |
| Open's fixed second | find why waiting for the window to be reported visible lost the first frame; candidates: the run loop not delivering AppKit's events, the window server not yet compositing the window | the startup probe on the Mac; Open must confirm on every one of 50 opens |
| Display capture | keep or drop by measurement | tear test and compositor probe (0.8.1 probes), with and without |
| ProMotion | refresh rate from `NSScreen.maximumFramesPerSecond` when the mode reports none | a ProMotion MacBook; the measured rate must match |
| Texture storage | GPU-only storage for textures written once, by blit | frame time drawing large images, before and after |
| Float textures | sample 32-bit float directly; no CPU conversion | as above, for a float image updated every frame |
| LinkInfo | keep (best effort) or drop | your decision (still open) |
| Keyboard queue | the polling fallback without Input Monitoring | kb_queue_demo with permission off |
| Interruptions | voices get an `Interrupted` end; after an interruption audio is restarted by PsychMetal, not left to the system; one behaviour on Mac and iOS | a call and Siri on the iPhone; unplugging the output on the Mac |
| Hardware matrix | 60 Hz and high refresh, HiDPI, two displays, iPad, background and resume | a written checklist run before release |
| Phone | Noise through a mask: removed from the phone in the 0.10.0 tree (kept on the Mac as an example of the stimulus calls); App Store submission | Apple's review |

## 6. Order of work

1. A `PsychMetal-0.10.0` tree from 0.9.0.
2. Arcs, ProMotion, the keyboard fallback check: small, and they clear the list.
3. Movie playback (part 1), with the synthetic test movie, then its sound (2).
4. Recording (3); offline first, since it is deterministic and makes the test
   movies for part 1; then live.
5. The measurement probes (4), so the hardware can be used as soon as it arrives.
6. Interruptions; Open's wait; display capture; texture storage, each with its
   measurement before and after.
7. The hardware matrix, and release.

Video is the bulk of the work. The order puts the things that can be finished
and tested off a Mac first, and leaves to the end the changes that, as in 0.9.0,
can only be judged on the hardware.

## 7. What to get for measuring

Prices change; these are the kinds of things, not endorsements.

- **An audio interface with two inputs**, class-compliant (it then works with an
  iPhone over USB-C too), line or instrument inputs, 48 kHz or more. One
  interface records the photodiode and the loopback or microphone on one clock.
- **A photodiode with a fast amplifier** and an analog output into a line input:
  a ready-made light-sensor module, or a silicon photodiode (BPW34 or similar)
  and a resistor. It must respond in well under a millisecond; most do.
  Something to hold it flat against the screen, light-tight.
- **A loopback cable** for the interface: output to input.
- **A small measurement microphone** for the speaker-to-ear check.
- Optional: a microcontroller board (a Teensy or similar) reading the photodiode
  and microphone with its own clock, as a check that does not rely on the
  computer's clocks at all.

## 8. Decided, and still open

- Names: `PsychMetal('OpenMovie', ...)` and `pm.open_movie(...)`, as above.
- Frame rates: equal whole refreshes per frame, nearest to the movie's rate,
  ties to the slower, no pulldown.
- Noise through a mask: off the phone; the Mac keeps it.
- Open: a movie's sound when its frames are slowed or sped up. 24 fps on a 60 Hz
  display plays 17 % slow. The choices: (a) resample, so the sound stays with
  the frames and drops in pitch by the same 17 %; (b) stretch it in time with
  Apple's time-pitch unit, which keeps the pitch but alters the sound in other
  ways; (c) refuse to play sound unless the movie's rate divides the refresh
  rate, and say so. Proposed: (c) by default, (a) or (b) when asked.
- Open: LinkInfo, keep or drop; and what Siri did on the phone with 0.9.0.
