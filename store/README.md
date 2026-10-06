# Google Play submission

The listing text is in `listing.md`. Artwork is in `assets/`.
Developer: Sergio A Marin. Support: sergio.alejandro.mz@gmail.com.
Privacy URL: https://highercomve.github.io/hollershare/privacy/.

## Build and signing

Run `oriel android init`, then `oriel android build -Dnative_ui -Doptimize=ReleaseSafe -Dplay-store=true`.
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
Download the `android` workflow artifact and upload `hollershare-android-app-release.aab` to Play Console.
Do not upload an APK in place of the AAB. Signing credentials stay in existing GitHub Actions secrets.

At initial Play App Signing enrollment, import the existing APK signing key if you want
GitHub APKs and Play installs to use the same signing identity. Register a separate upload
key afterwards. Configure that upload key for Play CI before future submissions; keep the
GitHub APK signing key separate. Do not publish private keystores or passwords in this repository.

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
