# PsychMetal 0.9.0 pre-release review — October 12, 2026

## Result

The available automated checks, native builds, Python distributions and offline
phone bundle checks pass after the corrections below. This is a reviewed
release candidate, not a published release or physical timing certification.
The phone project has been refreshed with the rebuilt device/simulator wheels.
No GitHub or App Store upload was performed.

## Scope

Reviewed the 0.9.0 changes to presentation and drawable ownership, compiled Metal
libraries, polygon rendering, input/keyboard queues, adaptive waits, shared image
and sound conversion, audio callbacks/host ownership, both language boundaries,
phone demo flows, versions, documentation, distributions and release workflows.
The previously reported retirement overflow and stale-handle issues now have
separate retirement acknowledgments and process-wide ids, with regression tests.
Mac audio settings restoration and asynchronous rate changes were also reviewed.

## Corrections made during this review

1. **Unaligned float texture data:** the image packer directly dereferenced
   potentially unaligned double/float addresses. The new regression reproduced
   an UndefinedBehaviorSanitizer failure. Loads now use memcpy, including for
   reversed/strided arrays; the regression passes.
2. **Voice key in the last recording buffer:** input is recorded before the
   voice key is evaluated. If StopRecording or memory exhaustion ended the
   recording in that buffer, a trigger lost its recording index. Membership
   now uses the saved sample range, retaining valid final-buffer indices and
   refusing indices for triggers after the recording. The new test failed
   before the fix and passes after it.
3. **Noise amplitude:** zero/negative values could construct a normal
   distribution with an invalid standard deviation. Negative amplitude is
   rejected, zero produces silence, and tiny positive amplitudes use a unit
   normal distribution scaled afterwards, avoiding an underflowed deviation.
4. **Sound sample range:** MakeSound accepted finite float values outside its
   documented -1..1 range. Large inputs could overflow mixing and produce NaNs.
   Loading now enforces normalized samples; use playback gain for amplification.
5. **Phone touch recovery:** both sound demos ignored lost touch events. A lost
   release could leave a button/drag held indefinitely. Lost events now clear
   remembered fingers; a scripted lost-release check verifies recording stops
   and subsequent Play/Quit actions work.
6. **Recorder state:** Python and MATLAB/Octave recorder demos now process End
   events only for the current recording and clear Recording when it fills.
7. **Checks and release notes:** the runner halts on undefined-behavior faults;
   otherwise UBSan can print errors and still return success. Validation counts
   were refreshed, breaking APIs are explicit in release notes, and the example
   CI workflow matches the repository workflow. Native CI jobs ensure the Metal
   compiler exists. CI moved to macOS 15: the macOS 14 runner is scheduled for
   removal November 2, per [GitHub's runner image notice](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

## Verified on these sources

- `make all`: Apple Silicon Octave, MATLAB and Python native binaries built.
- Full regression runner passed; scripted Octave inventory **249/249 across
  92 commands**; readback **46/46**. Engine type checks pass against real macOS,
  iOS device and iOS simulator SDKs. Audio host/core tests pass under memory,
  undefined-behavior and thread sanitizers.
- Mac Python 3.14 wheel rebuilt from the source distribution, imported separately
  from the checkout, and exercised through its native core. Source archive has
  the native sources and shader compiler helper, without prebuilt extensions.
- Both Python 3.14 iOS wheels rebuilt; all three wheels have fresh Python sources,
  only arm64 code, the expected platforms and minimum OS versions (Mac 14, iOS 15).
- Briefcase app sources/requirements refreshed and Xcode preparation rerun.
  Release-configuration device and arm64 simulator app builds pass. For offline
  checks the app executable is unsigned and embedded extensions are ad-hoc signed;
  these are not installable distribution archives or Apple validation results.
- Both apps pass verify_bundle.py and verify_privacy.py: version 0.9.0/build 1,
  **88 compatible frameworks each**, microphone usage text, current demos/app
  sources/resources, privacy manifests and valid _ssl/_hashlib module signatures,
  no static archives in the bundle.
- Relative Markdown links in package documentation resolve. Historical release
  records retain their historical version labels intentionally.

## Acceptance update — October 12, 2026

Keith supplied Mac hardware output: GPU polygon/custom-shader tests passed;
readback 46/46, startup 10/10, and both 600-frame motion runs at 60 Hz with no
long intervals passed. Inventory initially passed 248/249 with a relative-wait
median overshoot of 667.9 microseconds against a 600 microsecond tolerance;
the repeat passed 249/249. This intermittent timing result remains recorded.
Python and Octave sound demos completed; MATLAB was not shown in these logs.

Keith also reported that the iPhone tests work. The supplied launch/demo console
has no Python exception or Metal assertion, but a debugger was attached, so it
is not an undisturbed frame-timing measurement. Individual route/permission
scenarios were not separately logged. The built bundle contains the configured
Apple icon assets despite the runtime fallback warning.

[Linux/macOS CI](https://github.com/keiths0/PsychMetal/actions/runs/38310222083) and
[Mac wheel/source builds](https://github.com/keiths0/PsychMetal/actions/runs/38310243097) passed for source commit 90d6417.
Publication metadata is dated October 12; the package was regenerated after
these release-record edits. See VALIDATION.md for evidence and coverage limits.
No photodiode, microphone or loopback timing certification was performed.

## Performance and behavior limits to keep visible

GPU polygons cost vertex count times covered pixels. Very complex full-screen
polygons are not guaranteed faster than the previous rasterization approach;
cache static geometry in an offscreen texture and benchmark actual workloads.

Audio interruption recovery remains system-controlled: detection invalidates
`timed`, but does not provide a uniform Interrupted event/restart policy. The
50 ms callback-gap detector cannot detect audio that iOS merely mutes while
callbacks continue. Audio latencies remain software/device-reported values.
