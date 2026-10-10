# App Review notes

PsychMetal Demos is an educational app that demonstrates visual contrast and motion. No account, login, purchase, external hardware, or network connection is required to run the demonstrations.

To test:
1. Choose “Drifting stripes,” read the explanation, and tap “Start demonstration.”
2. Tap with three fingers together to return to the menu. This acts as Escape; there is no button overlay on the stimulus.
3. Choose “Blob array.” Hold one finger on a spot to drag it; release to leave it in place.
4. Optional: turn on “Diagnostic mode” and run “Frame timing.” A timing graph opens when it finishes. The report can be reopened from the menu.
5. With Diagnostic mode on, demonstrations collect timing statistics and continue through missed refreshes without capturing images or pausing. “View last demo output” opens the complete output on a scrollable page. These software timings are not a calibrated display measurement.

Some demonstrations contain rapid flicker; their descriptions explain this before they start. Rotation is chosen before starting a demonstration. The stimulus keeps that orientation while running.

The app bundles Python, its dependencies, all demonstration code and the native PsychMetal engine. It does not download code, expose a package installer, or accept user scripts. Python is an implementation detail, not a remotely extensible feature.

The help, privacy policy and open-source licenses are accessible in the app under “About, help & privacy.” No personal data or diagnostic results are sent to the developer by the app.

Review contact: Keith Schneider, keith@alumni.caltech.edu.
Enter the review contact telephone number separately in App Store Connect.

0.8.0 adds local report persistence and an explicit Share reports button. Sharing
uses the system share sheet; cancellation preserves reports. No automatic upload
or selected destination. Device reports include OS/GPU/engine/display metadata.
