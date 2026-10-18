# PsychMetal Demos — public edition

The iPhone/iPad app presents educational demonstrations of contrast, motion,
hidden boundaries and the timing of sight and sound. Each item has teaching notes before it starts. A **three-finger tap** returns to the menu. Diagnostic mode starts off.

All fifteen public non-keyboard MATLAB/Octave/Python demos are included; see
[DEMO-PARITY.md](DEMO-PARITY.md) for the mapping and touch controls.

The full developer tests remain in the toolbox; the public menu does not expose
keyboard-only or deliberately unsupported checks. `python/ring_check.py`, which
reads frames back to confirm the noise annulus's ring is drawn exactly, is one.

App Store description, review notes, static support/privacy web pages, icon
sources and submission instructions are in [store/SUBMISSION.md](store/SUBMISSION.md).
The generated project is not an App Store submission or a signed archive.

## Building

From this folder, on a Mac with Xcode and its iOS platform installed, and, with
Xcode 26 or later, its Metal compiler
(`xcodebuild -downloadComponent MetalToolchain`): the wheels embed the built-in
shaders compiled for the iPhone and the simulator.

1. Build the two Python 3.14 iOS wheels into this folder's `wheels/` directory.
   Use the 0.11.0 device/simulator release wheels, or build fresh wheels from this source. cibuildwheel needs python.org's
   Python 3.14 installed (the framework alone is enough), not Homebrew's.

       python3 -m venv ~/venvs/cibw && ~/venvs/cibw/bin/pip install cibuildwheel
       rm -rf wheels ../build
       CIBW_BUILD="cp314-ios_arm64_iphoneos cp314-ios_arm64_iphonesimulator" \
           ~/venvs/cibw/bin/cibuildwheel --platform ios .. --output-dir wheels

2. The app. Briefcase builds the app for the Python it runs under, so its
   environment must be python.org's Python 3.14, the version of the wheels
   (a Homebrew Python 3.15 makes it look for cp315 wheels, and none match):

       /Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14 -m venv ~/venvs/briefcase314
       ~/venvs/briefcase314/bin/pip install -U briefcase
       ~/venvs/briefcase314/bin/briefcase create iOS

   After a change to the demos or the app, `briefcase update iOS`; after a
   change to the engine, step 1 again and then `briefcase update iOS -r`.
   To refresh the icon, add `--update-resources`. After create/update, run
   `python3 store/prepare_xcode.py` to attach the privacy resource and sync the
   app configuration.

3. `briefcase open iOS`, choose the phone and a signing team in Xcode, Run.
   The launch screen covers normal Python/menu initialization; no extra logo
   delay is added. Its Gabor fades into black using separate pre-rendered
   `resources/launch-*.png` artwork. `store/prepare_xcode.py` reapplies these
   transparent assets and the black background after Briefcase updates. A distinct
   `PsychMetal Launch` storyboard and image resource avoid reusing the old
   icon-based launch artwork. The menu hero also has transparent fading edges;
   the app icon is
   unchanged. Regenerate only when editing the artwork with
   `python3 store/make_launch_art.py` (requires NumPy and Pillow).
   For timing tests, stop debugging and launch from the phone’s home-screen icon.

`build/`, `wheels/`, `logs/` and `.briefcase/` are what building leaves
behind, and are not kept in the repository.

## What is here

- `src/psychmetaldemos/catalogue.py`: the list. An entry is a title, a module,
  a function and its arguments.
- `src/psychmetaldemos/app.py`: the window. A demo is started with
  `psychmetal.start`, because on a phone the main thread belongs to the app.
- `finger_ring.py`: a demo written with fingers in mind. It runs on a Mac
  too. The hidden-ring demo is the package's `python/hidden_ring_demo.py`; its
  start page offers its two settings (`CHOICES` in `catalogue.py`).
- `pyproject.toml`: names the files of `../python` that go into the app.

`tests/test_phone_demos.py` checks the list and runs these demos against the
scripted engine. It does not make the app's window.

## 0.10.1 reports and offline preflight

Optional tests and all report/view/export tools are attached to the menu only
while Diagnostic mode is on; existing reports remain saved when it is off.
Diagnostic mode collects the native environment after a trial, outside its frame
loop. Last output/timing reports survive relaunch; timing reports retain their
own environment snapshot. “Share reports” opens the system sheet with HTML,
text and JSON files. The user chooses a destination or cancels; the app sends
nothing automatically. Device & presentation report also works before a demo.

After building, run `store/verify_bundle.py APP_PATH IOS` (or `IOSSIMULATOR`) and
`store/verify_privacy.py APP_PATH`. These inspect deployment metadata, privacy
resources, bundled source/assets and static archives, without uploading anything.
They do not replace Apple validation, actual MSL/GPU execution or device tests.

## Movies

Movie playback uses a bundled numbered sample with sound. Record a stimulus
uses the shared Python demo to write an H.264 movie with generated clicks in
app-local storage, then replays it. Share recorded movie saves/sends a snapshot
through the system sheet; cancelling preserves the original. This control is
available independently of diagnostics. No Photos picker or camera is used.

Export a stimulus writes a three-second frame-counted Gabor movie without
replacing the app window. It uses the same app-local destination and Share
recorded movie control. The user functionally checked export and recorded-movie replay on an iPhone.
Broader device/codec coverage and measured A/V onset remain unverified.
