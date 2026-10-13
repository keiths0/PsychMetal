# In-app frame timing report

Select **Frame timing** in the phone app's Tests group. Keep the phone still
for the alternating patch and untouched blob array, then drag a blob during
the third condition. Each condition has one nominal second of warm-up and
12 nominal seconds of recording. Three fingers end the test early and show
whatever was collected. The total is approximately 40 seconds, longer if
frames arrive slowly.

When the stimulus window closes, a scrollable report opens inside the app.
Each condition has a presentation-interval graph, confirmed/unconfirmed frame
counts, long-interval counts, median/99th-percentile/maximum intervals, and
CPU, drawable-wait, encoding and GPU timing summaries. With at least three
long intervals it also reports their median and maximum spacing.

**Back to demos** returns to the menu. **View last timing report** reopens the
most recent report, including after another demo has run. Results remain in
memory until the app exits or a new timing report replaces them. No files,
internet connection, plotting package or native-wheel rebuild are needed.
Take screenshots of the report to keep or share it.

Graphs use Metal's actual presentation timestamps, never projected Flip
times. An interval requires adjacent submitted frames with confirmed,
increasing timestamps. Missing timestamps break the line. The green line
shows the nominal interval; red dots mark intervals above 1.5 or below 0.5
times that interval. Long intervals are not by themselves proof of dropped
frames or a refresh-rate change. The separate delivery rate counts confirmed
frames over their elapsed time, including gaps between them.

This first diagnostic uses the existing engine diagnostics. It does not yet
record CADisplayLink callbacks or measure physical light output, and cannot
prove that ProMotion changed cadence. The CPU measurements add a few clock
reads per frame; report generation occurs after the stimulus windows close.
The third condition counts touch events on a phone, or held-button samples on
a Mac. A third condition with no recorded input did not test dragging.

For a baseline, use a cool phone with Low Power Mode off and launch the app
without Xcode's debugger attached. Keep the phone orientation unchanged during
a run. Repeat a run to distinguish recurring behavior from a one-off stall.

## Compare Game Mode on and off

The app opts into iOS Game Mode with `GCSupportsGameMode = true` in its
Briefcase iOS configuration. This requests support; it is not a measurement
of whether Game Mode is currently active.

Rebuild and install the app, then check for Game Mode in the system's Game
Overlay (open Control Centre while the app is running). Run **Frame timing**
once with Game Mode on and once with it off, keeping other conditions the
same. Change the setting before starting each test, not during recording.
Take screenshots of each report and note which setting was used. The report
does not automatically detect or label Game Mode's current state.

Game Mode reduces background activity but does not guarantee every deadline
or a fixed physical refresh rate. See [Apple's configuration guidance](https://developer.apple.com/videos/play/wwdc2024/10089/)
and [Game Mode controls](https://support.apple.com/105118).

Briefcase update copies Python code but does not refresh arbitrary Info.plist
keys in an existing Xcode project. The current local project has also been
patched with this Boolean; newly created projects inherit it from pyproject.toml.
