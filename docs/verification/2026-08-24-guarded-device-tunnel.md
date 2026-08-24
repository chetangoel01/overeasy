# Guarded local device tunnel

Date: August 24, 2026

## Purpose

Give signed iPhone development builds a temporary HTTPS route to the fully
working local Docker backend without exposing an unguarded API or relying on
the phone-incompatible `.localhost` hostname.

## Behavior and decisions

- `Backend/scripts/device_tunnel.sh rotate` starts an opt-in, loopback-only
  Nginx edge and rotates a 256-bit ngrok traffic-policy key before a new phone
  build.
- The ngrok process is owned by the macOS service manager so it survives the
  terminal command that created it. `start` reuses the active key for an
  installed build; `stop` closes the endpoint and restores simulator routing.
- The generated `.private/DeviceTunnel.xcconfig` is ignored by Git, mode `600`,
  and supplies the HTTPS API URL, tunnel key, and local-backend App Attest
  setting without printing the key.
- Missing and incorrect keys return `404`. OpenAPI, Swagger, ReDoc, and metrics
  remain hidden even with the correct key. Nginx removes the tunnel-only
  headers before proxying to FastAPI.
- Private thumbnails use short-lived MinIO signatures through the same HTTPS
  endpoint. Their object path is exempt from the app-only header so native
  image loading works, while unsigned bucket access remains rejected.
- Rotating the key intentionally invalidates older local-tunnel builds. Release
  and TestFlight builds continue to use the separately guarded VPS.

## Affected components

- `Backend/docker-compose.yml`
- `Backend/deploy/mac-mini/ngrok.sh`
- `Backend/scripts/device_tunnel.sh`
- `Backend/README.md`
- `Backend/docs/integration-reference.md`
- `README.md`
- Backend deployment-policy tests

## Verification

- The new profile and launcher tests failed before implementation and passed
  after it; all 13 focused deployment-policy tests pass.
- Both shell launchers pass `sh -n`, and normal plus tunnel-profile Compose
  configurations pass `docker compose config --quiet`.
- The tunnel process remains active under `launchctl`, while Docker publishes
  its ingress only at `127.0.0.1:4114`.
- Missing key: `404`; incorrect key: `404`; authorized readiness: `200`;
  authorized metrics: `404`.
- A real tunnel journey created a guest (`201`), loaded six Discover results,
  and fetched a tunnel-signed JPEG thumbnail (`200`) without the app key.
- Xcode resolves the HTTPS endpoint, a present 64-character key, and
  `LADLE_APP_ATTEST_ENABLED=NO` from the private xcconfig.
- Focused `APIClientTests` and the runtime tunnel-configuration smoke test pass,
  including preservation of bearer authorization plus both tunnel headers.
- A signed generic iOS Debug build succeeded for team `P48VDW72LU`, embedded
  the guarded URL and key, disabled App Attest for local Compose, and contained
  the Share Extension.
