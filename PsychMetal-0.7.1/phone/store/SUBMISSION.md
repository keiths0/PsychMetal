# PsychMetal Demos: submission handoff

The 0.7.1 public edition is prepared locally. It has not been uploaded to
App Store Connect, submitted for review, or published on the App Store.

## Prepared

- Curated, touch-friendly menu with explanations before each demonstration.
- Three-finger tap returns to the menu; no stimulus overlay.
- Diagnostic mode off by default; full developer tests remain in the toolbox.
- Original Gabor + psychometric-curve icon, all required icon/splash sizes.
- Offline help, privacy policy and bundled third-party license texts.
- Store description, reviewer instructions, support and privacy web pages.
- App privacy manifest for local elapsed timing and app-container file metadata.

## First verify the app

Open the 0.7.1 Xcode project and run on your device. Check every menu entry,
portrait and landscape, three-finger exit, background/foreground recovery,
help/privacy navigation, and diagnostic reports/inspection. Also test a 60 Hz
phone and an iPad before claiming those devices have been validated. Confirm
the icon on the Home Screen. Developer automated tests are not device acceptance.

Captured frames do not record the panel itself.

## Prepare Xcode after future updates

From the `phone` directory:

```bash
~/venvs/briefcase/bin/briefcase update iOS -r --update-resources
python3 store/prepare_xcode.py
~/venvs/briefcase/bin/briefcase open iOS
```

Rebuild the iOS wheels first whenever native engine code changes; instructions
are in ../IOS.md and phone/README.md. `prepare_xcode.py` makes resource/plist
changes reproducible after Briefcase regeneration; it does not sign or upload.

## Remaining owner actions

1. Confirm paid Apple Developer enrollment and the seller identity (you or your
   institution). Select that team in Xcode. Keep the existing bundle identifier
   unless you intentionally want a different app identity.
2. Host `site/index.html` and `site/privacy.html` publicly over HTTPS. Verify them
   without signing in, then paste their URLs into App Store Connect. Confirm that
   the existing public contact email is the address you want to use.
3. Create the app record in App Store Connect and use APP-STORE-LISTING.md. The
   app name's availability, price and territories have not been set remotely.
4. Take real screenshots of the finished public build: home menu, Blob array,
   Drifting stripes and Hidden ring. Add iPad screenshots if distributing on iPad.
   Follow the screenshot dimensions requested by App Store Connect. No simulated
   marketing screenshots have been substituted for actual app screenshots.
5. In Xcode, select a device destination and Product > Archive (Release). In
   Organizer choose Validate App, inspect the privacy report, and resolve all
   signing, SDK, privacy-manifest or embedded-framework findings. See PRIVACY-AUDIT.md.
6. Distribute App > App Store Connect > Upload. Do not choose TestFlight Internal
   Only if this build is intended for public App Review. Increment the build
   number for each subsequent upload of this version.
7. Test through TestFlight, including an external tester after beta review.
8. Complete App Privacy, age rating, encryption/export-compliance questions,
   review contact phone number and availability in App Store Connect. The app
   does not itself implement encrypted communication; bundled Python libraries
   may contain cryptography, so review the actual archive rather than copying
   an unverified “no encryption” exemption into Info.plist.
9. Select the build, paste REVIEW-NOTES.md, and submit for review. Choose manual
   release if you want control over the publication date after approval.

The source-level privacy review supports “Data Not Collected” for the app's
own functionality. Verify the complete archive and dependencies before making
that declaration. No paid membership, legal agreement, privacy declaration or
submission has been made on your behalf.

## References checked October 8, 2026

- https://developer.apple.com/app-store/submitting/
- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- https://developer.apple.com/news/upcoming-requirements/?id=02032026a
- https://briefcase.beeware.org/en/stable/reference/platforms/iOS/xcode/
