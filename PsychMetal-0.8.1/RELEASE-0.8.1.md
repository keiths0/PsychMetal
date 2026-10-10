# PsychMetal 0.8.1

Patch release for iPhone report sharing and menu recovery. The share panel now
uses a scene-connected UIKit window, fixing the narrow first-launch panel without
requiring a stimulus demo to run first. Cancellation restores the menu and its
controls. Sharing errors wrap and scroll, and About shows the current version.

It also fixes issues found in the 0.8.0 review: Python stop/close/argument corrections,
custom shader wrapper order and full compile errors, MATLAB/Octave parity
(DrawStimulus argument order, RecentFrames, ExportEnvironment, Resolution),
a decaying WaitSecs spin margin, and release-tree cleanup. See CHANGELOG.md.
Native binaries and phone wheels are rebuilt from the finalized 0.8.1 sources. No video or audio
support is added. Version 0.8.0 remains the unchanged published release.

See VALIDATION.md for completed checks and remaining device acceptance.
GitHub publication is separate from the App Store; no new Apple upload is included.
