# 0.8.0 phone build validation — October 10, 2026

Fresh device/simulator CPython 3.14 wheels and both Release Xcode builds passed.
Offline bundle inspection passed for 88 frameworks in each app: platform,
minimum OS compatibility, current Python/app/shader resources, no static archives,
app privacy manifest, and both embedded OpenSSL module manifests/signatures.
Preparation also aligns the support Python.framework metadata before embedding.

Generated project: `build/psychmetaldemos/ios/xcode/PsychMetal Demos.xcodeproj`.
Built products: `build/validation-device/Build/Products/Release-iphoneos/` and
`build/validation-simulator/Build/Products/Release-iphonesimulator/`.
App version 0.8.0, build 1; no upload, developer-signed archive or Apple validation.

Portable UI tests cover persistence, explicit sharing/cancellation, iPad popover
configuration, report routing and main-thread idle GC. They cannot certify UIKit
behavior, GPU-generated pixels or timing. Real device checks remain: new masked
image/custom shader/timeline demos, report reopen/share/cancel, portrait/landscape,
background/resume and repeated demo/menu transitions under Main Thread Checker.
Run timing separately from Home Screen with Xcode disconnected.

See ../../VALIDATION.md for complete results and limitations.
