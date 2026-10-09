# Privacy review: source checked, archive validation pending

Reviewed public catalogue, app entry points, bundled help/report pages, Python
wrappers and native iOS presentation/input code. The menu runs local code and
local procedural visual patterns. There are no accounts, analytics, ad SDKs,
tracking domains, automatic uploads, or network requests in these app paths.
Bundled help and report pages use local HTML with no remote scripts/images.
External support links are user-initiated. This is a source review, not a network
traffic capture or an Apple validation result.

Touch positions, rendering times, and rendered-image snapshots stay in process
memory. Reports can remain in memory while the app is open. Python/runtime files
and OS diagnostic logging are distinct from an app data-collection service.

The app privacy manifest declares:

- NSPrivacyTracking: false; no tracking domains or collected data types.
- SystemBootTime / 35F9.1: measuring intervals between app events, including frame
  presentation. PsychMetal uses monotonic clocks. No boot time is sent off device.
- FileTimestamp / C617.1: file metadata for bundled Python imports and files
  inside the app's own container. No file metadata is sent off device.

Before upload, generate Xcode's privacy report for the actual archive and review
all embedded Python, NumPy, Toga, Rubicon and other dependency frameworks. A root
app manifest is not a substitute for any manifests Apple requires in individual
SDK/framework bundles. There were no .xcprivacy files found in the installed
Python wheel tree before adding this app manifest. Dependency signatures,
required-reason API declarations and any other App Store validation findings
remain an archive-level check. Do not add reasons unrelated to actual use just
to suppress a validation finding.

Encryption/export-compliance answers have deliberately not been invented;
check the archive's bundled libraries before answering Apple's questionnaire.

References:
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
