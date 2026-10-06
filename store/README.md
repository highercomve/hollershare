# Google Play submission

The listing text is in `listing.md`. Artwork is in `assets/`.
Developer: Sergio A Marin. Support: sergio.alejandro.mz@gmail.com.
Privacy URL: https://highercomve.github.io/hollershare/privacy/.

## Build and signing

Run `oriel android init`, then `python3 scripts/configure-android-symbols.py`, then `oriel android build -Dnative_ui -Doptimize=ReleaseSafe -Dplay-store=true`.
Oriel 0.9.3 generates API 36 and Android Gradle Plugin 8.9.3 projects directly.
For an older generated project, use `oriel android init --force` after saving your edits.
CI installs Gradle 8.14.3, Java 21 and Android platform 36.

The Play option disables GitHub update checks and offers no external APK update action.
It preserves package ID `dev.hollershare.App`, version name `1.0.0`, and version code `10000`.
Each later Play upload needs a larger version code. Increase the app version before
generating the project and building the next upload; Oriel derives the code from major.minor.patch.
For example, 1.0.1 gives version code 10001. Regenerate edited Gradle files with `--force`
after preserving customizations so the manifest metadata follows the new app version.

For a signed CI build, dispatch **Build and release** on main with:
`sign=true`, `publish=false`, `platform=android`, `play_store=true`.
Download the `android` workflow artifact and upload `hollershare-android-app-release.aab` to Play Console. The AAB includes matching native debug symbols; the artifact also contains `hollershare-android-native-debug-symbols.zip` for manual upload in App Bundle Explorer. Symbols must come from the same build as the uploaded bundle; rebuilding an older source revision does not guarantee matching addresses.
Do not upload an APK in place of the AAB. Play builds use the dedicated
`PLAY_ANDROID_KEYSTORE_BASE64`, `PLAY_ANDROID_KEYSTORE_PASSWORD`, `PLAY_ANDROID_KEY_ALIAS`
and `PLAY_ANDROID_KEY_PASSWORD` GitHub Actions secrets. Other builds use the original
`ORIEL_ANDROID_*` secrets. CI rejects Android Debug certificates for Play builds.

The existing GitHub APK key has an Android Debug certificate and must not be used for
Google Play. For the initial Play App Signing enrollment, let Google generate the app
signing key and register the dedicated HollerShare upload certificate. The upload key
signs AAB submissions; Google signs the installed APKs. Existing GitHub APK installations
will need to be uninstalled before installing the Play version because their signing
identities differ. Back up received files before uninstalling.
To distribute matching APKs elsewhere later, download Google's signed universal APK
from Play Console. Keep the upload key and password backed up securely outside Git.
Do not publish private keystores or passwords in this repository.
The public upload certificate is `play-upload-certificate.pem`; its SHA-256 fingerprint
is `64febc106d0538116332c0d28751c95a6460897e3ee4d5072e5eaa18a18ebcd2`.

## Console setup

1. Complete account identity and physical-device verification in Play Console.
2. Create HollerShare as a free app. Check the developer name and support address.
3. Add the listing text, icon, feature graphic and real phone screenshots.
4. Add the published privacy URL and complete Data safety, ads, app access, target audience,
   content rating and any other declarations Play Console requests. The app has no login or ads;
   explain that reviewing transfers needs a second device on the same network.
5. Upload the signed Play AAB to internal testing and review the pre-launch report.
6. Start closed testing with at least 12 testers continuously opted in for 14 days, collect
   feedback and fix issues. This requirement applies to this new personal developer account.
7. Apply for production access and submit for review when testing is complete.

## Data safety review

Do not equate "no analytics" with "no data handling". Review the form definitions against
`site/content/privacy.smd`: selected files and text are sent to user-chosen recipients;
nearby devices see advertised names, device/discovery identifiers and network addresses;
settings, received files and diagnostics live locally. The Play build makes no GitHub update checks.
Consider the user-initiated transfer exceptions in Google's form guidance before choosing answers.
No final Data safety declaration has been submitted or approved by this repository.

## Validation and remaining checks

Check bundle signatures, package ID, API target, version code, ABI coverage and 16 KB native
alignment. Test discovery, incoming consent, file/text sharing, folder selection, clipboard
behavior, permission denials and the offline privacy panel on Android 16.
Store screenshots must show the actual Android app; website diagrams are not app screenshots.

Official references:
- https://support.google.com/googleplay/android-developer/answer/11926878
- https://developer.android.com/build/releases/about-agp
- https://developer.android.com/studio/publish/app-signing
- https://support.google.com/googleplay/android-developer/answer/14151465
- https://support.google.com/googleplay/android-developer/answer/10144311
- https://support.google.com/googleplay/android-developer/answer/10787469
- https://support.google.com/googleplay/android-developer/answer/9866151

## Artwork

- `assets/play-icon.png`: 512×512, 32-bit RGBA, full square artwork; Play applies its own mask.
- `assets/feature-graphic.png`: 1024×500, RGB PNG.
- SVG sources are next to both raster assets. Regenerate with `rsvg-convert`, then ensure
  the icon uses RGBA and the feature graphic uses RGB.
- Phone screenshots are captured from the actual app, without promotional overlays.
  `assets/screenshots/01-share-files.png` and `02-share-text.png` are 1080×1920 captures
  from the native Play build on an Android 16/API 36 emulator (360 dpi).

Local validation passed: API 36 release compilation, Android target type checking,
launching on Android 16, switching file/text modes, opening and closing the offline
privacy policy, and displaying the Google Play update status. Transfer testing on
physical devices and the Play pre-launch report remain part of internal testing.
A desktop-to-emulator encrypted text transfer also passed after incoming consent;
the received text was copied to Android's clipboard and pasted back into the composer.
A 4,600-byte file transfer passed after consent, saved to the default Android folder,
and matched the original byte for byte.
