# PsychMetal Demos 0.8.1 submission handoff

Version 0.8.1, build 1, with the existing app identity. It has not been uploaded to Apple. The 0.7.1 build-4 record is BUILD-4-0.7.1.md.

## Local preparation

The app has the public menu, three-finger return, optional diagnostics with saved
and shareable reports, original icon, offline help/privacy and the shared demos.
It carries the App Store static-library, framework-metadata and OpenSSL privacy
fixes from 0.7.1. ../../CHANGELOG.md lists the engine changes since then.
Fresh device/simulator wheels and an unsigned Xcode project were built locally.
See VALIDATION.md for precise checks and hardware limits.

After later source changes, from this candidate's phone directory:

```bash
~/venvs/briefcase/bin/briefcase update iOS -r --update-resources
python3 store/prepare_xcode.py
~/venvs/briefcase/bin/briefcase open iOS
```

Rebuild native wheels first whenever engine code changes; phone/README.md gives
the commands. Run prepare_xcode.py after every create/update. It excludes static
archives and corrects converted framework minimum-version/package-type metadata
before signing. It does not sign a distribution archive or upload anything.

## Before a future submission

1. Test every demo on iPhone and iPad, both orientations, touch/three-finger exit,
   background recovery, help and scrollable reports. Measure timing with Xcode
   disconnected. Confirm the app's About page and the native engine both report 0.8.1.
2. Use an Apple-accepted public Xcode toolchain to rebuild wheels and the app,
   select your existing signing team and device destination, then Product > Archive.
   The local compilation used Xcode 27.1 (27A9275); compilation success alone does
   not establish App Store toolchain eligibility.
3. Validate the new archive and inspect its privacy/dependency/signing findings.
   Upload it to the existing App Store Connect app, version 0.8.1. Increase the
   build number for each additional upload of this version. Wait for server-side
   processing before selecting the build.
4. Reuse the existing app record and published support/privacy URLs. Update
   screenshots/listing/reviewer notes only where the new version requires it;
   complete the version's compliance fields and review submission when ready.
   Export compliance is answered in Info.plist (ITSAppUsesNonExemptEncryption
   false: the app uses no encryption of its own), so uploads do not ask again.

Support: https://keiths0.github.io/PsychMetal/psychmetal-demos/

Privacy: https://keiths0.github.io/PsychMetal/psychmetal-demos/privacy.html

The generated Xcode project is local build output, not committed source. The
previous Xcode Cloud workflow expected this generated project in GitHub; a local
archive/upload does not require that workflow. No cloud configuration was changed
by this preparation.

Missing symbols for prebuilt Python/NumPy frameworks need matching vendor dSYMs
for full symbolication; a fabricated empty dSYM does not fix that warning.
