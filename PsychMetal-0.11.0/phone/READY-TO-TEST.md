# 0.11.0 phone build: what to check

App version: 0.11.0; build: 1. No App Store upload is included in the GitHub release.
Build with fresh 0.11.0 device and simulator wheels; see README.md. After an
engine change, rebuild the wheels and run `briefcase update iOS -r` and
`python3 store/prepare_xcode.py`. Open the generated project:

```sh
open "$HOME/Developer/PsychMetal/PsychMetal-0.11.0/phone/build/psychmetaldemos/ios/xcode/PsychMetal Demos.xcodeproj"
```

Choose your device and signing team, then Run. For timing, stop debugging and
launch from the Home Screen. Then run `python3 store/verify_bundle.py APP IOS`
and `python3 store/verify_privacy.py APP` on the built app.

## Rotation and transforms (new in this release)

The engine change needs fresh wheels and an app rebuild (above); the demos are
the toolbox's own, so nothing else changes in the app.

1. Shapes: nearly everything turns. Each rectangle, oval, frame and arc turns
   about its own centre; the lines and the ring of round dots turn as a set
   (the dots still run along their three-lobed contour); the Gabor patch turns
   while its stripes drift; the star, hexagon, triangle and the three blending
   ovals turn as groups. In the text panel "Metal" spins about its middle, the
   second word swings, and "Aa" grows and shrinks: check that the spinning
   word looks clean and that "Aa" stays sharp at its largest.
2. Ring of rectangles: each rectangle now turns with the ring, staying square
   to it, as the ring follows your finger.
3. Both in portrait and landscape; three fingers returns. Frame rate should
   be unchanged from before (the turning is done by the GPU's vertex shaders).

## Carried over from 0.8.1

Sharing: open Share reports before running any demo, cancel, reopen sharing, and
start a demonstration. Check About shows 0.11.0. (Full-width sharing,
cancellation recovery and report export passed on the phone for 0.8.1 on
October 10.)

Diagnostic menu: on launch, optional tests and report tools are absent. Turn
Diagnostic mode on to reveal them, then off to hide them. Turning it on again
must retain saved reports. About/help remains available in either mode.

## Existing sound demos (introduced in 0.9.0)

1. The menu has a Sound and time section with both demos and their pictures.
2. Sound recorder, first run: the system asks for the microphone. Allow it. The
   picture moves when you speak. Hold Record, speak, lift; the status line gives
   the recording's length and peak. Tap Play: the recording plays from the
   **loudspeaker**, not the earpiece, and the status line names the output.
3. Refused microphone: turn the app's microphone access off in Settings, open
   the recorder. It ends with a message saying where to turn access on; it does
   not say the demonstration failed.
4. Headphones: with wired headphones the recorder plays into them. Unplugging
   them while it runs is an interruption from 0.11.0: the demo stops at its next
   sound with the interruption message (item 6). With Bluetooth
   headphones the matching demo plays into them and shows a note that their
   delay is not measured; the recorder, which opens the microphone, stays on the
   phone's own speaker and microphone.
5. Matching flicker and sound: the switches change what is matched and whether
   each is seen or heard; the dial (phase) and slider (frequency) move by
   finger; Match shows the error. Nothing plays when both are seen.
6. Interruption (0.11.0): start a sound demo, then take a call (a FaceTime
   audio call from a Mac will do) or ask Siri something during a tone. At the
   next sound it starts, the demo stops with "The sound was interrupted (a call,
   Siri, or headphones plugged in or out), so the demonstration stopped. Start it
   again to go on." Starting it again works. If Siri only silenced the app
   without stopping its output, nothing is detected (the limit in ../AUDIO.md).
   Unplugging wired headphones during a sound demo stops it the same way.
7. Three fingers leave both sound demos at any time, as Quit does.

## Existing movie demos (introduced in 0.10.0)

- Movie playback: numbered frames and sound, followed by the rotating movie.
- Record a stimulus: drifting Gabor fading into the background, dot, counter; on the
  first click the dot holds at three o'clock for half a second and resumes where it
  stopped; then the replay shows the same.
- Share recorded movie: with diagnostics off, save to Files, cancel and reopen.
  Sharing must not leave demo controls disabled. Restart the app: the completed
  movie remains available. A failed recording must preserve the previous file.
- Run movies in portrait and landscape; labels avoid the camera housing.

New standalone export check: Export a stimulus should leave the menu window in
place while writing a three-second movie. Share recorded movie should provide a
640x480, 180-frame H.264 Gabor clip. Check duration and motion in the exported
file. During export, backgrounding must stop further GPU submissions safely;
the previous completed movie must survive a failed replacement.

Export completion: Create movie should lead to a Movie ready page showing
180 frames / 3 seconds, with Play exported movie, Share movie and Back to demos.
Preview must play the exported Gabor clip, not the numbered bundled sample.
Cancelling sharing must re-enable Share movie; missing/empty exports must open
an error page even when Diagnostic mode is off.

## Remaining-wishlist engine refresh (October 15)

The rebuilt engine uses bounded movie lookahead and warms playback before its
A/V start. Recheck bundled Movie playback, Record a stimulus (including replay
sync and duration), Export a stimulus, and share/cancel recovery. Older iPhones
retain half-float image uploads when 32-bit filtering is unsupported.

Mac-only follow-up: run PsychMetalOpenReadyTest(50), then the performance audit
in ../python/performance_audit.py. Verify unplug/reconnect recovery with sound
and optional recording; interrupted playback must stop, loaded sound handles
must remain usable, and timing must stay invalid after the route change.
All-intra conversion and preload APIs are documented in ../MOVIES.md.
Do not infer photon/speaker timing from the software offset reports.

## Demo launch pages (October 15)

A large filled Start demo button is fixed at the top of each demonstration page.
Hidden ring shows full-width speed/cell sliders below it, with current numeric
values and range endpoints. Both sides of each track have explicit colours.
Settings and instructions scroll below the fixed Start button. Export uses Create movie. Check these
controls on the smallest supported phone and in landscape; option selection and
three-finger return retain their existing behavior.

## New 0.10.1 demos

HDR brightness: circular 7x7 pairwise flicker comparisons, with 0.5..16x steady
circular references below. Row/column levels alternate with equal whole-frame
holds near the chosen target (16 Hz by default); diagonal controls stay constant.
Check single-finger Slower/Faster taps (including quick taps) during playback and
changes applying only after a complete cycle. Live headroom updates twice
per second; stars mark reference requests above current headroom. Check
portrait/landscape, diagonal controls, frame-rate label and final report. Devices without potential EDR headroom
show an explicit error. This is not nits calibration.
GPU image processing: original/blur/sharpen/grey+blur panels should look distinct.
Streaming sound: move horizontally to change pitch smoothly; inspect underflow
samples in diagnostic output. Three fingers returns in all three demos.
Keith confirmed these Mac and phone checks work on October 16, 2026; see
../VALIDATION.md. Individual phone timing/underflow results were not supplied.

## Noise controls and categories

Ring of rectangles appears under Shapes and textures. Noise contains Changing
noise and Hidden ring. Changing noise offers cell size (1..5 display pixels)
and frames per update (1..60). Try 3-pixel cells and 7 frames per update: cells
should have hard edges and each pattern should hold for seven presentations.
Three fingers exits. Hidden ring retains its existing controls.

Changing noise also has a numbered button: 1. Binary noise, 2. Grayscale noise,
3. Colored noise. Tap to cycle before starting. Check black/white-only binary
cells, continuous gray values, and independent RGB values; cell size and frames
per update apply to all three. The selected type stays fixed during the run.
