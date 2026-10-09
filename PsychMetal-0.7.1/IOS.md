# PsychMetal on iPhone and iPad

Status: the native engine supports iOS 15+, while the demo app requires iOS 17+
and uses CAMetalDisplayLink by default. The user accepted the current phone
menu, stimuli and interaction. In on-device testing, disconnecting Xcode
eliminated the recurring long presentation intervals seen while debugging.
This is a user-reported observation on the tested device, not a guarantee across
iPhones or a measurement of emitted light. No photodiode validation is claimed.
See [VALIDATION.md](VALIDATION.md) and [phone timing notes](phone/FRAME-TIMING.md).

## What it is

The same engine with a second platform layer. Drawing, textures, text, the
queue, readback and the Python front end are the Mac's code. What differs is
how the window is made and where input comes from, and that is
`PsychMetalIOS.h`, included once into `PsychMetalEngine.mm` when the target is
iOS. MATLAB and Octave do not exist there; Python is the only front end.

An experiment is an ordinary psychmetal script. On a phone the main thread
belongs to the app, so the app starts the script with `pm.start(fn, done=...)`
and the engine puts its own window over the app's until the script closes it.

## What is different from the Mac

- One screen, one mode, at its native pixels. `set_mode` fails; `screen` must be 0.
- 8 bits per channel. `bit_depth=10` is refused.
- The display is always synchronized; asking otherwise fails.
- An iPhone gives an app 60 Hz unless the app's Info.plist sets
  `CADisableMinimumFrameDurationOnPhone`. Low Power Mode holds any device to
  60 Hz; opening a window then warns.
- Fingers are the mouse and one key, so that a program written for a mouse and
  a keyboard runs unchanged. One finger is the pointer (`get_mouse`). A second
  finger down is button 1, at the pointer (`get_mouse`, `mouse_events`). A
  third finger down is the Escape key (`kb_check`, the keyboard queue). The
  pointer is the finger that went down when none was; when it lifts, the
  pointer stays where it was. `touch_events` reports every finger as it is.
  Tapping a place is therefore not a click there: a program that wants taps
  reads `touch_events`.
- `set_mouse` sets where the pointer is taken to be until a finger next goes
  down; showing and hiding the cursor do nothing.
- Other keys come from an attached keyboard only, with the events' times.
- `link_info` reports no link.
- If the app stops being in front (a call, Control Centre, the home gesture),
  the next flip raises and the window must be closed. A swipe from a screen
  edge goes to the experiment first; a second one reaches the system.

## The simulator

The simulator's drawables do not report when they were shown, so there the
time a frame's rendering finished stands in for it. Programs run; no time
taken in the simulator says anything about a device.

## What an app cannot control

True Tone, Night Shift and automatic brightness are the user's settings. An
app cannot turn them off and cannot find out whether True Tone or Night Shift
is on. Colour and luminance on a phone are therefore the experimenter's to
fix by hand in Settings before a session. The window's colour space is not
yet set or checked on iOS; how drawn values map to a P3 panel is unmeasured.

## Building, and the app

Wheels: `cibuildwheel --platform ios` on a Mac with Xcode, for iOS 15 and
later (`[tool.cibuildwheel.ios]` in pyproject.toml). cibuildwheel wants
python.org's Python for the version it builds, not Homebrew's. The wheel goes
into an app built with Briefcase.

`phone/` is such an app: a list of this package's own demos and tests, taken
from `python/` as they are, and a page for what each prints. Its README has
the steps. A few of the demos need a keyboard, and a few tests expect what a
phone does not have (a 10-bit window, a display that can be left
unsynchronized); the list says which.

## The Mac's side of the same thing

`touch_events` (`TouchEvents` in MATLAB and Octave) also reports the Mac's
trackpad: each finger resting or moving on it, placed in the window as it is
placed on the trackpad. The trackpad goes on driving the pointer and its click
is the button, and the window takes contacts only once a program has asked
for them, so nothing that worked changes. The first call starts listening and
returns nothing. Written and type-checked; not yet run. AppKit delivers a contact only while the pointer is over the window
and the program is the active application, and whether it does so with the
display captured is not yet known.

## Not done

- Any timing, and the package's own tests, on a device.
- The window's colour space (above).
- `tests/test_fingers.py` runs the rules for fingers; nothing else in
  `PsychMetalIOS.h` is run by a test, only compiled.
- Choosing a script that is not built into the app.
