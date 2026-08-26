# Guarded Local Device Tunnel

**Original capability:** August 24, 2026

**Consolidated:** August 26, 2026

## Purpose

Give signed iPhone development builds a temporary HTTPS route to the local
Docker backend without exposing an unguarded API or relying on the
phone-incompatible `.localhost` hostname.

## Behavior

- `Backend/scripts/device_tunnel.sh rotate` starts an opt-in, loopback-only
  Nginx edge and rotates a 256-bit ngrok traffic-policy key before a new phone
  build.
- The ngrok process is owned by the macOS service manager so it survives the
  terminal that created it. `start` reuses the active key for an installed
  build; `stop` closes the endpoint and restores simulator routing.
- The generated `.private/DeviceTunnel.xcconfig` is ignored by Git, mode `600`,
  and supplies the HTTPS API URL, tunnel key, and local-backend App Attest
  setting without printing the key.
- Missing and incorrect keys return `404`. OpenAPI, Swagger, ReDoc, and metrics
  remain hidden even with the correct key. Nginx strips tunnel-only headers
  before proxying to FastAPI.
- Private thumbnails use short-lived MinIO signatures through the same HTTPS
  endpoint. Their object path is exempt from the app-only header so native
  image loading works, while unsigned bucket access remains rejected.
- Rotating the key intentionally invalidates older local-tunnel builds.
  Release and TestFlight builds continue to use the separately guarded VPS.

## Historical device evidence

The source branch recorded a launchd-owned tunnel, loopback-only Docker
ingress, the `404/404/200/404` guard sequence, a guest creation, six Discover
results, a signed thumbnail fetch, Xcode configuration resolution, focused
client tests, and a signed device build containing the Share Extension. This
preserves the physical-device evidence without printing or reusing its secret.

## Consolidation verification

- Edge-profile and launcher tests were added before implementation and failed
  because the profile, lifecycle support, and build-config script were absent.
- Three focused tunnel regressions passed.
- The complete deployment test directory passed: 49 tests.
- Both shell launchers pass `sh -n`; normal and tunnel-profile Compose
  configurations pass `docker compose config --quiet`; Ruff passes.
- Seven `APIClientTests` and two runtime tunnel-configuration smoke tests pass.
- A generic iOS Debug build containing the Share Extension succeeds without
  signing. It exposes the existing `GoogleSignInProvider` non-Sendable
  completion warning, which remains open in the consolidation cleanup ledger.
