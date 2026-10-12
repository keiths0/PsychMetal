# 0.9.0 phone build: what to check

App version: 0.9.0; build: 1. No App Store upload is included in the GitHub release.
Build with fresh 0.9.0 device and simulator wheels; see README.md. After an
engine change, rebuild the wheels and run `briefcase update iOS -r` and
`python3 store/prepare_xcode.py`. Open the generated project:

```sh
open "$HOME/Developer/PsychMetal/PsychMetal-0.9.0/phone/build/psychmetaldemos/ios/xcode/PsychMetal Demos.xcodeproj"
```

Choose your device and signing team, then Run. For timing, stop debugging and
launch from the Home Screen. Then run `python3 store/verify_bundle.py APP IOS`
and `python3 store/verify_privacy.py APP` on the built app.

## Carried over from 0.8.1

Sharing: open Share reports before running any demo, cancel, reopen sharing, and
start a demonstration. Check About shows 0.9.0. (Full-width sharing,
cancellation recovery and report export passed on the phone for 0.8.1 on
October 10.)

Diagnostic menu: on launch, optional tests and report tools are absent. Turn
Diagnostic mode on to reveal them, then off to hide them. Turning it on again
must retain saved reports. About/help remains available in either mode.

## Sound (new in 0.9.0)

1. The menu has a Sound and time section with both demos and their pictures.
2. Sound recorder, first run: the system asks for the microphone. Allow it. The
   picture moves when you speak. Hold Record, speak, lift; the status line gives
   the recording's length and peak. Tap Play: the recording plays from the
   **loudspeaker**, not the earpiece, and the status line names the output.
3. Refused microphone: turn the app's microphone access off in Settings, open
   the recorder. It ends with a message saying where to turn access on; it does
   not say the demonstration failed.
4. Headphones: with wired headphones the recorder plays into them; unplug them
   while it runs and playback returns to the loudspeaker. With Bluetooth
   headphones the matching demo plays into them and shows a note that their
   delay is not measured; the recorder, which opens the microphone, stays on the
   phone's own speaker and microphone.
5. Matching flicker and sound: the switches change what is matched and whether
   each is seen or heard; the dial (phase) and slider (frequency) move by
   finger; Match shows the error. Nothing plays when both are seen.
6. Interruption: with Diagnostic mode on, start a sound demo, then take a call
   (a FaceTime audio call from a Mac will do). Audio stops, and may resume
   afterwards, as iOS decides; the app does not crash. Quit; View last demo
   output shows the route warning, also when an earlier run in the same launch
   showed one. Then the same with Siri during a tone: iOS posts no notice for
   Siri, but 0.9.0 also notices when the output stops for over 50 ms, so if
   Siri stops the output the warning says "the output stopped for a while". If
   no warning appears, Siri only silenced the app (the limit in AUDIT-0.9.0.md).
7. Three fingers leave both sound demos at any time, as Quit does.
