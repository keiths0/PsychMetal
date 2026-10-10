# 0.8.0 prepared phone build

The local project is already generated with fresh 0.8.0 device/simulator wheels.
Device and simulator Release builds, package metadata and privacy checks passed.
This folder is independent of the 0.7.1 App Store submission. Nothing was uploaded.

When ready, open the prepared project:

```bash
open "$HOME/Developer/PsychMetal/PsychMetal-0.8.0/phone/build/psychmetaldemos/ios/xcode/PsychMetal Demos.xcodeproj"
```

Choose your signing team and connected device, then Run. Developer signing and
actual launch are separate from the completed offline builds. If sources change,
use the existing Briefcase environment, `briefcase update iOS -r`, then
`python3 store/prepare_xcode.py` before reopening/building the project.

A focused later device check:

1. Run Image through apertures and Custom GPU spiral; check rendering and exit.
2. Enable Diagnostic mode, run Native timeline, exit with three fingers; repeat.
3. Open timing and environment reports; share, cancel, reopen, then relaunch to
   check persistence. On iPad check the anchored Share sheet in both orientations.
4. Separately use Main Thread Checker for repeated demo/menu/background/resume
   transitions. The idle-main-thread GC change still needs this real UIKit check.
5. For frame timing, launch from Home Screen with Xcode disconnected. Software
   confirmation is not photodiode validation of emitted light.

See ../VALIDATION.md for explicit skips and limitations. Video/audio are deferred.
