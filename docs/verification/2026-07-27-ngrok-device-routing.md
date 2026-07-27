# Temporary ngrok device routing

## Purpose

Give a Personal Team iPhone build a temporary HTTPS route to the Mac mini
development API without requiring Tailscale or MagicDNS on the phone.

## User-visible behavior

An explicitly configured device build reads `LadleTunnelAccessKey` and adds it
as `X-Ladle-Tunnel-Key` to every API request, including guest bootstrap, token
refresh, imports, and sync. Normal builds leave the setting empty and send no
tunnel header.

The Mac mini exposes a third Nginx listener on loopback port `4114` for ngrok.
It treats ngrok as the HTTPS terminator, preserves the forwarded client
address, hides OpenAPI, interactive docs, ReDoc, and metrics, enforces the
existing 1 MiB request limit, and removes the tunnel key before proxying to the
API.

## Important decisions

- `LADLE_TUNNEL_ACCESS_KEY` is empty in both checked-in xcconfigs. The
  short-lived value is generated outside source control and embedded only in
  the temporary device build.
- The ngrok Traffic Policy must return `404` unless the request carries that
  exact key. This avoids replacing the API's bearer `Authorization` header
  with HTTP Basic authentication.
- Port `4114` remains bound to `127.0.0.1`; only an agent running on the Mac
  mini can reach it. Tailscale remains the persistent staging ingress.
- This is development access, not a production deployment. Stop the ngrok
  endpoint and replace the temporary device build when testing ends.

## Affected components

- `Ladle/App/LadleApp.swift`
- `Ladle/Remote/APIClient.swift`
- `Config/Ladle-Info.plist`
- `Config/{Debug,Release}.xcconfig`
- `Backend/deploy/mac-mini/{docker-compose.yml,nginx.conf}`
- `LadleTests/{APIClientTests,ProjectSmokeTests}.swift`
- `Backend/tests/unit/deploy/test_mac_mini_profile.py`

## Verification

- The focused iOS regressions first failed because the runtime key and
  `APIClient` initializer did not exist.
- The Mac mini profile regressions first failed because port `4114` and the
  tunnel listener did not exist.
- Final test, deployment, tunnel-policy, and physical-device results are
  recorded after the endpoint is live.
