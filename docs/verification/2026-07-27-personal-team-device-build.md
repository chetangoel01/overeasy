# Personal Team device build

## Purpose

Allow an explicitly configured development build to use the private Tailscale
backend when Apple Personal Team signing cannot provision App Attest.

## User-visible behavior

The default Debug and Release builds still initialize App Attest. A device
build made with `LADLE_APP_ATTEST_ENABLED=NO` skips App Attest and can create a
guest session against a development backend that does not enforce attestation.
This switch must not be used with an App-Attest-enforcing environment.

## Decisions and affected components

- `LadleRuntimeConfiguration` reads `LadleAppAttestEnabled` from the app bundle
  and defaults to enabled when the setting is absent or unrecognized.
- `LadleApp` omits the shared `AppAttestClient` only when that setting is
  explicitly false.
- Both checked-in xcconfigs keep the setting enabled. The Personal Team device
  command overrides it alongside the entitlement-free signing configuration.
- `Config/Ladle-Info.plist`, `Ladle/App/LadleApp.swift`, and
  `LadleTests/ProjectSmokeTests.swift` contain the configuration and regression
  coverage.

## Verification

- The focused regression test first failed because the runtime switch did not
  exist.
- All eight `ProjectSmokeTests` passed after implementation.
- The signed device build passed with `LADLE_APP_ATTEST_ENABLED=NO`, an empty
  development entitlement file, and the private Tailscale API URL. Its
  expanded Info.plist contains both overrides.
- The corrected build installed and launched on the paired iPhone. A fresh
  guest bootstrap set the expected local account state.
- Neither that bootstrap nor an independent Safari request to `/health/ready`
  reached Nginx. Tailscale's app and network-extension processes are running,
  but the iPhone tunnel still needs to be connected before the final
  iPhone-to-backend check can pass.
