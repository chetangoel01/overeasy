# Temporary ngrok device routing

## Purpose

Give a Personal Team iPhone build a temporary HTTPS route to the Mac mini
development API without requiring Tailscale or MagicDNS on the phone.

## User-visible behavior

An explicitly configured device build reads `LadleTunnelAccessKey` and adds it
as `X-Ladle-Tunnel-Key` to every API request, including guest bootstrap, token
refresh, imports, and sync. It also opts API requests out of ngrok's browser
interstitial. Normal builds leave the setting empty and send neither header.

The Mac mini exposes a third Nginx listener on loopback port `4114` for ngrok.
It treats ngrok as the HTTPS terminator, preserves the forwarded client
address, hides OpenAPI, interactive docs, ReDoc, and metrics, enforces the
existing 1 MiB request limit, and removes the tunnel key before proxying to the
API.

The same listener proxies private-bucket thumbnail reads. Recipe responses
carry short-lived S3 signatures, so image requests are authorized by their
signature rather than by the app-only tunnel header.

## Important decisions

- `LADLE_TUNNEL_ACCESS_KEY` is empty in both checked-in xcconfigs. The
  short-lived value is generated outside source control and embedded only in
  the temporary device build.
- The ngrok Traffic Policy must return `404` unless the request carries that
  exact key, except for `/ladle-private/` object reads carrying a valid MinIO
  signature. This avoids replacing the API's bearer `Authorization` header
  with HTTP Basic authentication and lets native image loading work without
  exposing the bucket.
- Port `4114` remains bound to `127.0.0.1`; only an agent running on the Mac
  mini can reach it. Tailscale remains the persistent staging ingress.
- Bucket initialization reads the lifecycle policy baked into the backend
  image. It does not mount a host file, avoiding Docker Desktop file-sharing
  stalls when the deployment runs from a hidden Git worktree.
- The thumbnail backfill uses the migration service image rather than cloning
  the API service, so it does not contend for the API's fixed edge-network
  address during a rolling deployment.
- This is development access, not a production deployment. Stop the ngrok
  endpoint and replace the temporary device build when testing ends.

## Affected components

- `Ladle/App/LadleApp.swift`
- `Ladle/Remote/APIClient.swift`
- `Config/Ladle-Info.plist`
- `Config/{Debug,Release}.xcconfig`
- `Backend/deploy/mac-mini/{docker-compose.yml,nginx.conf,worker-egress.sh}`
- `Backend/deploy/mac-mini/ngrok.sh`
- `Backend/ladle/{admin/cache_cli.py,imports/thumbnail_backfill.py}`
- `LadleTests/{APIClientTests,ProjectSmokeTests}.swift`
- `Backend/tests/unit/deploy/test_mac_mini_profile.py`

## Verification

- The focused iOS regressions first failed because the runtime key and
  `APIClient` initializer did not exist.
- The Mac mini profile regressions first failed because port `4114` and the
  tunnel listener did not exist.
- All 15 focused `APIClientTests` and `ProjectSmokeTests` passed. The added
  ngrok browser-interstitial assertion also passed independently.
- All seven Mac mini deployment regressions passed, and `ngrok.sh` passed
  `sh -n`.
- Commit `db2cbea` is deployed on the Mac mini. The edge container is healthy
  with port `4114` bound only to host loopback.
- The live ngrok policy returned `404` for a missing key, `404` for a wrong
  key, `200` for keyed readiness, and `404` for keyed metrics access.
- Xcode exposed the first temporary key in verbose build output. That key and
  endpoint were discarded and rotated before installation. The final silent,
  clean build embedded the rotated key and
  `https://6072-2603-7002-1500-16-90c7-c848-df5a-c70a.ngrok-free.app`.
- The final build contains the app and Share Extension, is signed by the
  Personal Team, and installed successfully on the paired iPhone running iOS
  27.0.
- The physical-device launch reached the API through ngrok: guest bootstrap
  returned `201`, followed by a recipe sync returning `200`.
- The replacement share-fix build keeps the same guarded ngrok route while
  adding the Personal Team-compatible shared-Keychain handoff. Its packaged
  IPA SHA-256 is
  `ec6d63cd6fd8edbfe7f2814ee421a2046d230f39d3437bce0d64a5b3de323a47`.

### Signed-thumbnail deployment

- Mac mini commit `6bf3153` is deployed. PostgreSQL, Redis, MinIO, API, worker,
  beat, worker egress, and edge containers are healthy.
- Deployment initialized the private, versioned `ladle-private` bucket and
  backfilled two legacy cache thumbnails. The database now has two
  object-backed cache rows and two object-backed recipe images, with zero
  provider-remote thumbnail rows remaining.
- The live ngrok policy returns `404` for readiness without the tunnel key and
  `200` with the key. A five-minute signed thumbnail URL uses the active ngrok
  host and returns `200` without the app-only header; the same object path
  without its signature returns `403`.
- Docker Desktop 4.66.1 accepted container creation but stalled start requests
  through its API proxy. The deployment completed through Docker Desktop's
  local raw engine socket using the same Compose configuration; the normal
  loopback bindings and ngrok route were verified afterward.
- Physical release build `20260727.2` launched through the route, refreshed an
  expired access token successfully, and completed recipe sync with `200`.
