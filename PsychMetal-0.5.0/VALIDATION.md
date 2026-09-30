# Validation of PsychMetal 0.4.3

## Final ready build, 17 September 2026

Keith tested the binary subsequently renamed from PsychMetal-0.4.3-ready-candidate to PsychMetal-0.4.3 in Octave on a 6016×3384 display reporting 60 Hz.

- Inventory: 151/151 checks passed across 49 public commands; deliberate misuse was rejected.
- Open readiness: 10/10 repeated opens passed, alternating five immediate and five scheduled first stimuli, with backgrounds 0, 32 and 64. Every first stimulus was confirmed (status 0).
- Startup confirmation: 3–5 attempts, 88–115 ms. Whole OpenWindow calls: approximately 1.38–1.47 s.
- Scheduled first stimuli: reported presentation 9.380–12.954 ms after the requested time, within one 60 Hz refresh. These results do not demonstrate zero scheduling error or physical onset accuracy.

OpenWindow submits the requested background until two consecutive presentations are confirmed. The confirmation loop has a 12-attempt/2-second limit; this is not a hard bound on all macOS window-creation or operating-system waits. Startup diagnostic records are separate from the user stimulus history.

## Earlier optimization-stage measurements

These measurements support the retained changes but were not all rerun on the final readiness binary:

- Upload optimization, 1024×1024 motion: 600/600 confirmed frames, 60.000 Hz, no long adjacent intervals, median upload 3.505 ms.
- Upload optimization, 2048×2048 motion: 600/600 confirmed frames, 59.602 Hz, four long adjacent intervals, median upload 7.370 ms. The user confirmed matching rightward motion in both panels.
- 2048 grayscale acceptance arm improved from 40.022 Hz/299 skipped refreshes to 59.800 Hz/two skipped refreshes; median upload dropped from 14.594 to 7.179 ms. Eight acceptance arms had 4800/4800 confirmed measured presentations in that candidate.
- Input-optimized timing candidate: six arms of 780 measured frames (4680 total), all confirmed, 60 Hz, no long measured intervals. Unconfirmed warm-up presentations remained before the later OpenWindow readiness integration.
- Avoiding Secure Input owner lookup reduced measured KbCheck medians from roughly 2.5–2.6 ms to 0.437–0.449 ms. Owner lookup remains available in KbQueueStatus outside timing-critical loops.

## Automated coverage and limits

The included runner exercises wrapper mocks, headless native argument/queue behavior, extracted native mouse/drawing/packing/timing/startup code and a synthetic native keyboard worker with sanitizers. An offscreen Metal test explicitly skips if no GPU is accessible. Mocks and extracted tests do not establish visual or OS input correctness.

Both ARM64 binaries were built. The Octave library dependency is installation-specific; MATLAB R2026a compilation is not equivalent to MATLAB hardware acceptance. Switching native builds after opening graphics requires restarting the host because the MEX is deliberately pinned for callback safety.

There is no photodiode validation, no physical input-to-photon measurement, no exhaustive multi-display or variable-refresh validation, and no guarantee of uninterrupted 60 Hz for arbitrary workloads. The package cleanup preserves the tested runtime files and binaries byte-for-byte. See RELEASE-INVENTORY.md for the packaging audit.
