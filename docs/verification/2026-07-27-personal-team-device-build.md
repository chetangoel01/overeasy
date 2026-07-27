# Personal Team device build

## Purpose

Allow an explicitly configured development build to use a development backend
and accept links from its Share Extension when Apple Personal Team signing
cannot provision App Attest or App Groups.

## User-visible behavior

The default Debug and Release builds still initialize App Attest. A device
build made with `LADLE_APP_ATTEST_ENABLED=NO` skips App Attest and can create a
guest session against a development backend that does not enforce attestation.
This switch must not be used with an App-Attest-enforcing environment.

The normal Share Extension uses the App Group file queue. If that container is
unavailable, the Personal Team build stores durable share envelopes in a
shared Keychain access group. The main app reconciles the same queue when it
starts or becomes active. The user still sees the normal “Added to Overeasy”
confirmation in the share sheet.

## Decisions and affected components

- `LadleRuntimeConfiguration` reads `LadleAppAttestEnabled` from the app bundle
  and defaults to enabled when the setting is absent or unrecognized.
- `LadleApp` omits the shared `AppAttestClient` only when that setting is
  explicitly false.
- Both checked-in xcconfigs keep App Attest enabled. The Personal Team device
  command explicitly disables it.
- `SharedKeychainImportQueue` stores one JSON envelope per generic-password
  item. It preserves queue idempotency and deterministic ordering and removes
  malformed records so they cannot block later shares.
- The app and Share Extension prefer the existing App Group file queue. They
  fall back to Keychain only when the App Group container is unavailable.
- Both binaries use the same
  `$(AppIdentifierPrefix)com.ladle.shared` Keychain access group. The
  temporary Personal Team entitlement file contains only that supported
  capability.
- `Config/Ladle-Info.plist`, `Ladle/App/LadleApp.swift`, and
  `LadleTests/ProjectSmokeTests.swift` contain the runtime configuration and
  regression coverage.
- `Packages/LadleCore/Sources/LadleCore/SharedKeychainImportQueue.swift`,
  `LadleShare/ShareViewController.swift`, and
  `Ladle/Import/SharedQueueReconciler.swift` contain the fallback handoff.

## Verification

- The focused regression test first failed because the runtime switch did not
  exist.
- The Keychain queue regressions first failed because its queue and storage
  types did not exist. All three pass after implementation.
- All 40 `LadleCore` tests pass.
- The focused Share Extension, queue reconciler, and runtime configuration
  tests pass on an iPhone 17 Pro simulator.
- The signed device build passed with `LADLE_APP_ATTEST_ENABLED=NO`, the
  shared-Keychain-only development entitlement file, and the temporary ngrok
  API URL.
- The built app and extension signatures both contain
  `P48VDW72LU.com.ladle.shared`, and both expanded Info.plists contain that
  exact access-group value.
- The corrected build installed and launched on the paired iPhone. A fresh
  guest bootstrap set the expected local account state.
- Neither that bootstrap nor an independent Safari request to `/health/ready`
  reached Nginx. Tailscale's app and network-extension processes are running,
  but the iPhone tunnel still needs to be connected before the final
  iPhone-to-backend check can pass.
- The share-fix build installed and launched on the paired iPhone. Sharing a
  Safari URL through “Add to Overeasy” displayed the normal success path; when
  Overeasy became active, the API accepted the reconciled import with `202`,
  repeated status requests returned `200`, and the worker received the import
  task.
- The packaged share-fix IPA is
  `/tmp/Overeasy-1.0-20260726.2-ngrok-share-fix.ipa`; its SHA-256 is
  `ec6d63cd6fd8edbfe7f2814ee421a2046d230f39d3437bce0d64a5b3de323a47`.
