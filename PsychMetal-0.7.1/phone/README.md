# PsychMetal Demos — public edition

The iPhone/iPad app presents educational demonstrations of contrast, motion
and hidden boundaries. Each item has teaching notes before it starts. A **three-finger tap** returns to the menu. Diagnostic mode starts off.

All nine non-keyboard MATLAB/Octave/Python demos are included; see
[DEMO-PARITY.md](DEMO-PARITY.md) for the mapping and touch controls.

The full developer tests remain in the toolbox; the public menu does not expose
keyboard-only or deliberately unsupported checks. The previous catalogue is
preserved in `src/psychmetaldemos/developer_catalogue.py` for reference.

App Store description, review notes, static support/privacy web pages, icon
sources and submission instructions are in [store/SUBMISSION.md](store/SUBMISSION.md).
The generated project is not an App Store submission or a signed archive.

## Building

From this folder, on a Mac with Xcode and its iOS platform installed.

1. Put the two Python 3.14 iOS wheels from the [0.7.1 release](https://github.com/keiths0/PsychMetal/releases/tag/v0.7.1)
   into this folder's `wheels/` directory, or build psychmetal for the phone there. cibuildwheel needs python.org's
   Python 3.14 installed (the framework alone is enough), not Homebrew's.

       python3 -m venv ~/venvs/cibw && ~/venvs/cibw/bin/pip install cibuildwheel
       rm -rf wheels ../build
       CIBW_BUILD="cp314-ios_arm64_iphoneos cp314-ios_arm64_iphonesimulator" \
           ~/venvs/cibw/bin/cibuildwheel --platform ios .. --output-dir wheels

2. The app. In a Python environment with Briefcase (`pip install briefcase`):

       briefcase create iOS

   After a change to the demos or the app, `briefcase update iOS`; after a
   change to the engine, step 1 again and then `briefcase update iOS -r`.
   To refresh the icon, add `--update-resources`. After create/update, run
   `python3 store/prepare_xcode.py` to attach the privacy resource and sync the
   app configuration.

3. `briefcase open iOS`, choose the phone and a signing team in Xcode, Run.
   For timing tests, stop debugging and launch from the phone’s home-screen icon.

`build/`, `wheels/`, `logs/` and `.briefcase/` are what building leaves
behind, and are not kept in the repository.

## What is here

- `src/psychmetaldemos/catalogue.py`: the list. An entry is a title, a module,
  a function and its arguments.
- `src/psychmetaldemos/app.py`: the window. A demo is started with
  `psychmetal.start`, because on a phone the main thread belongs to the app.
- `finger_ring.py`, `noise_annulus.py`, `ring_check.py`: three demos written
  with fingers in mind. They run on a Mac too.
- `pyproject.toml`: names the files of `../python` that go into the app.

`tests/test_phone_demos.py` checks the list and runs these demos against the
scripted engine. It does not make the app's window.
