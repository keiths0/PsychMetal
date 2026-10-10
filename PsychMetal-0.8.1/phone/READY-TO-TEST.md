# 0.8.1 prepared phone build

Fresh 0.8.1 device/simulator wheels and app sources are installed in the generated
Xcode project. Unsigned device and ARM64 simulator Release builds and bundle/privacy checks pass.
App version: 0.8.1; build: 1. No App Store upload is included in the GitHub release.

Open the generated project:

```sh
open "$HOME/Developer/PsychMetal/PsychMetal-0.8.1/phone/build/psychmetaldemos/ios/xcode/PsychMetal Demos.xcodeproj"
```

Choose your device and signing team, then Run. Repeatable smoke test: open Share reports
before running any demo, cancel, reopen sharing, and start a demonstration. Check
About shows 0.8.1. Full-width sharing and cancellation recovery were confirmed
on the phone. The user also confirmed the final-build sharing/cancellation/demo-launch
and report-export smoke test passed on October 10.

Diagnostic menu check: on launch, optional tests and report tools should be absent.
Turn Diagnostic mode on to reveal them, then off to hide them. Turning it on again
must retain saved reports. About/help remains available in either mode.
