# PsychMetal 0.9.0

Audio. Sounds are preloaded and start and stop on the sample nearest a GetSecs
time, or a set time after a queued frame's projected presentation, and every
start and end is reported with the time it played. Any playing sound can be
amplitude-modulated, and the modulation is computed for each sample from that
sample's time, so a modulated sound and a frame drawn for its presentation time
follow the same function of one clock. Input records on exact samples into
memory set aside when it opens, with a one-shot voice key and a live monitor of
the newest input. Python, MATLAB and Octave have the same commands; the Mac uses
Core Audio and the iPhone/iPad the audio session. Audio has its own lock, so a
sound can be scheduled while another thread draws. See AUDIO.md.

This release also changes existing APIs. PrepareFlip/PresentNow,
SetDisplaySync and PrefetchDrawable are removed, together with OpenWindow's
waitForConfirm, displaySync and captureDisplay options (and their Python names).
Use Flip or QueueFlip; the engine manages drawable prefetch. Diagnostic now has
25 fields and frame history has 14 columns, so update code that indexes those
columns. WhiteNoise seeds produce different samples from 0.8.x. See CHANGELOG.md
for the complete migration details.

GPU polygons now use an even-odd fill and round outline corners. Their cost
grows with vertex count times covered pixels; for a complex static polygon,
render once into an offscreen texture and reuse it rather than redrawing it
across the full screen every frame.

Two demos, on the Mac and in the phone app: a live spectrogram of the microphone
with a hold-to-record recorder, and phase and frequency matching between a blob
flickering from grey to white and an amplitude-modulated tone, each seen or
heard. The matching demo uses only frequencies the measured refresh rate can
show with an even number of frames per cycle, so every cycle shows its peak and
its trough.

The real-time core and session code are plain C++, run in the tests sample for
sample against a simulated device that plays and records through a loopback.
On hardware they have been run on a Mac and an iPhone, by ear and by eye: the
times they report are the times Core Audio and the audio session report, and
have not been measured with a microphone, a photodiode or a loopback cable. A
loudspeaker, a display's own processing and a device that misreports its latency
all add delay that no software sees. Bluetooth and AirPlay outputs are refused
for timed playback unless asked for.

Also fixed: a monitor read that never succeeded when a buffer arrived during it,
iPhone recorder playback that went to the earpiece, route warnings iOS raised
for the app's own audio settings, and the races and lifetimes in
AUDIT-0.9.0.md. A refused microphone is its own error, PsychMetal:Microphone.
See CHANGELOG.md, and AUDIT-0.9.0.md for the audit, its fixes and two stated
limits: no interruption policy of PsychMetal's own, and no measured audio timing.

Video is deferred to 0.10.0. See VALIDATION.md for completed checks and
the remaining release checks. GitHub publication is separate from the App Store;
no Apple upload is included.
