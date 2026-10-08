# PsychMetal Demos

An app for an iPhone or iPad that lists the demos and tests in `../python`,
runs them as they are, and shows what each prints. Built with
[Briefcase](https://briefcase.beeware.org).

The demos were written for a mouse and a keyboard. On a phone, fingers are
both: one finger is the pointer, a second finger down is the click, a third
is Escape. So "click to stop" is a tap with a second finger. Some of them were
laid out for a screen wider than it is tall: turn the phone before starting
one, since the window keeps the way the phone was held when it opened.

**Blob array** uses direct one-finger dragging: touch a blob, move it, and lift to leave it. Three fingers stop it. Its layout fits portrait or landscape.

**Frame timing** runs three short conditions and opens an in-app graph and statistics report when finished. No files are saved. See [FRAME-TIMING.md](FRAME-TIMING.md).

## Building

From this folder, on a Mac with Xcode and its iOS platform installed.

1. psychmetal for the phone, into `wheels/`. cibuildwheel needs python.org's
   Python 3.14 installed (the framework alone is enough), not Homebrew's.

       python3 -m venv ~/venvs/cibw && ~/venvs/cibw/bin/pip install cibuildwheel
       rm -rf wheels ../build
       CIBW_BUILD="cp314-ios_arm64_iphoneos cp314-ios_arm64_iphonesimulator" \
           ~/venvs/cibw/bin/cibuildwheel --platform ios .. --output-dir wheels

2. The app. In a Python environment with Briefcase (`pip install briefcase`):

       briefcase create iOS

   After a change to the demos or the app, `briefcase update iOS`; after a
   change to the engine, step 1 again and then `briefcase update iOS -r`.

3. `briefcase open iOS`, choose the phone and a signing team in Xcode, Run.

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
