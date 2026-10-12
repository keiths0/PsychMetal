# OpenSSL module privacy manifests

The bundled Python support package omitted module-level manifests for _ssl and
_hashlib. This produces ITMS-91061 even when the app has its own manifest.
prepare_xcode.py supplies missing per-module manifests to all device/simulator
support slices. The upstream helper moves each into its generated framework as
PrivacyInfo.xcprivacy before codesigning. Existing vendor manifests are preserved.

OpenSSL.xcprivacy is the unmodified manifest from BeeWare Python-Apple-support
PR 285 (patch/Python/OpenSSL.xcprivacy), sourced there from OpenSSL. It declares
file timestamp access C617.1, no collected data and no tracking. This app performs
no network requests; it does not remove Python SSL/hash functions or alter binaries.

Source: https://github.com/beeware/Python-Apple-support/pull/285
Issue: https://github.com/python/cpython/issues/132006
Apple: https://developer.apple.com/support/third-party-SDK-requirements/

Run preparation after Briefcase create/update and make a NEW archive. Existing
archives and already uploaded builds are not changed. Inspect the final archive's
Frameworks/_ssl.framework/PrivacyInfo.xcprivacy and
Frameworks/_hashlib.framework/PrivacyInfo.xcprivacy, then validate/upload.
Apple server-side acceptance remains to be confirmed after the new upload.
