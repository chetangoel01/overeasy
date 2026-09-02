# Overeasy goes to TestFlight

Date: September 2, 2026
Status: **archive built and inspected; the upload is blocked on an App Store
Connect API key, which only Chetan can create.**

The app has only ever been installed over a cable, one device at a time. This
records what a TestFlight build needs, and leaves the whole run behind one
command so the second upload is not another afternoon of archaeology.

## What ships

Version **1.0**, build **20260902.1** — a date with a counter, so a build
number is never reused and reading one tells you when it was cut.

The Release configuration is what makes this a real build rather than a
developer's laptop build, and it was worth confirming rather than assuming:

| Setting | Value | Why it matters |
| --- | --- | --- |
| `LADLE_API_BASE_URL` | the VPS over https | a tester has no `api.ladle.localhost` |
| `APP_ATTEST_ENVIRONMENT` | `production` | Apple rejects a store build carrying the development environment |
| `LADLE_APP_ATTEST_ENABLED` | `NO` | attestation stays off until the server enforces it |
| `ITSAppUsesNonExemptEncryption` | `false` | no export-compliance question on every upload |

## The pieces

`Config/ExportOptions.plist` exports for `app-store-connect` with automatic
signing against team `P48VDW72LU`, uploads symbols so crash reports
symbolicate, and sets `manageAppVersionAndBuildNumber` to false — Xcode
silently renumbering a build would defeat the scheme above.

`Tools/release/testflight.sh` archives, exports, validates, and uploads.
`--validate-only` stops after validation, which runs the same checks Apple
runs on receipt without spending a build number; that is the way to try a
change. `--archive-only` needs no credentials at all.

Credentials come from the environment — `LADLE_ASC_KEY_ID`,
`LADLE_ASC_ISSUER_ID`, `LADLE_ASC_KEY_PATH` — and never from the repository.
`altool` takes a key identifier rather than a path and searches a few fixed
directories for the file, so the script points `API_PRIVATE_KEYS_DIR` at
whichever directory the key actually lives in.

## Decisions

**The `.p8` already in `.private/` is not the key this needs.** It is the
Sign in with Apple key the backend signs client secrets with
(`LADLE_APPLE_PRIVATE_KEY_PATH`). App Store Connect API keys, Sign in with
Apple keys, and APNs keys all arrive as `AuthKey_<KEYID>.p8` and are
indistinguishable by inspection, so the distinction is recorded here rather
than rediscovered.

**Internal testers first.** An internal group is App Store Connect users on
the team: no Beta App Review, no privacy policy URL, available as soon as
processing finishes. An external group or a public link puts the build through
review, and HealthKit and Sign in with Apple will both want explaining. That
is a decision for when there are testers who are not Chetan.

## Two things a tester inherits

**`LADLE_TUNNEL_ACCESS_KEY` ships inside the build.** It is an Info.plist
value, so anyone holding the `.ipa` can read it, and TestFlight hands the
build to Apple and to every tester. While that key is what gates the VPS API,
distributing the app distributes the key.

**The deployment target is iOS 26.5**, so a tester below that will not see the
build at all.

## Verification

`xcodebuild archive` at `-configuration Release` succeeded, and the archive
was read back rather than trusted: bundle `com.ladle.ios`, version `1.0`
(`20260902.1`), display name Overeasy, the VPS URL, `appattest-environment`
of `production`, `LadleShare.appex` embedded, and dSYMs for both.

Four validation failures were ruled out before archiving, each of which
rejects an upload rather than a build:

- `TARGETED_DEVICE_FAMILY` is `1`, so the three supported orientations cannot
  trip the iPad multitasking rule (ITMS-90474).
- `Config/LadleShare-Info.plist` carries the same `$(MARKETING_VERSION)` and
  `$(CURRENT_PROJECT_VERSION)` as the host app (ITMS-90473).
- The app icon is 1024×1024 with no alpha channel.
- `Ladle/Resources/PrivacyInfo.xcprivacy` is present.

Still unverified, and only provable by running it: the export step re-signs
with a distribution certificate that does not currently exist in the keychain.
Store provisioning profiles for both bundle identifiers were created on
August 23 and are still valid, so either the certificate is cloud-managed and
the export creates it, or one is registered to the team with its private key
on another machine. The export error will say which.
