> Historical record of the 0.7.1 build-4 App Store correction, kept from the
> removed PsychMetal-0.7.1 working folder. Paths below refer to that folder (tag v0.7.1).

# Corrected App Store submission: 0.7.1 build 4

This fixes ITMS-91061 for _ssl.framework and _hashlib.framework. The demos still
work offline. Python includes these modules even though our code does not use
SSL. The fix embeds the upstream OpenSSL manifests before signing each framework.

From Terminal:

```bash
cd "$HOME/Developer/PsychMetal/PsychMetal-0.7.1/phone"
python3 store/prepare_xcode.py
~/venvs/briefcase/bin/briefcase open iOS
```

In Xcode select the existing PsychMetal Demos scheme and Any iOS Device (arm64),
with your usual signing team. Choose Product > Clean Build Folder, then Product >
Archive. Use the public Xcode installation accepted by Apple, as for build 3.
Confirm version 0.7.1 and build 4 in the new archive. Old archives are unchanged.

In Organizer choose Distribute App > App Store Connect > Upload. After Apple's
processing succeeds, open the existing app's iOS 0.7.1 version in App Store
Connect. Select build 4 in its Build section, replacing build 3, save, and submit
that version for review again. If it remains locked in review, remove the current
submission from review first, then select the replacement build. No new app record
or marketing version is needed; preserve the product-page information.

Check the archive before uploading:

```bash
python3 store/verify_privacy.py "/path/to/PsychMetal Demos.xcarchive"
```

The verifier checks the app version/build and both embedded manifests and framework
signatures. It does not upload or establish server-side Apple acceptance.
