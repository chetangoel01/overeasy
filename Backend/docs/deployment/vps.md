# Ladle VPS deployment

Ladle runs on one modest Ubuntu VPS and is sized for roughly 100 users. The
deployment intentionally favors a small, understandable system over a private
platform.

## Runtime

Five containers stay running:

- `api`: two Uvicorn processes;
- `worker`: four Celery worker slots plus the single embedded Beat scheduler;
- PostgreSQL 16;
- Redis 7 for Celery, rate limits, and small operational counters;
- MinIO for private recipe thumbnails.

`migrate` and `minio-init` are one-shot Compose services. The shared Caddy
gateway at `/opt/platform/gateway` is the only public listener. It connects
directly to `ladle-api` and `ladle-minio` on the external `platform-edge`
network. PostgreSQL and Redis stay on Ladle's private Compose network.

The API has ample capacity for 100 users. Four imports can run concurrently;
additional imports queue in Redis rather than spawning more infrastructure.
Increase worker concurrency only after CPU and queue measurements justify it.

The checked-in environment defaults to production and enforced App Attest. A
guarded internal TestFlight backend may explicitly set
`LADLE_ENVIRONMENT=development`, `LADLE_ATTESTATION_ENFORCED=false`, and
`LADLE_APP_ATTEST_ENVIRONMENT=development` while keeping
`LADLE_INTERACTIVE_DOCS_ENABLED=false` and disabling App Attest in the
corresponding internal app build. Do not use that exception for an unguarded
public service or an external App Store release.

Compose probes every service every five seconds during its first minute so
deployment readiness stays fast, then backs all Docker health checks off to a
five-minute interval. Three consecutive failures are required before a service
becomes unhealthy. The explicit `manage.sh health` command still checks full
API readiness and worker response before a deployment succeeds. Do not use full
readiness as a frequent Docker probe; it contacts every dependency and wakes a
Celery CLI process even when the application has no work.

## Host layout

```text
/opt/ladle/
  .env                         production configuration, mode 0600
  app/                         current source archive
  secrets/                     Apple private key, mode 0700
/opt/platform/gateway/
  routes/ladle.caddy           shared gateway route
/var/backups/ladle/            PostgreSQL and MinIO backups
```

The Compose volumes keep their existing names (`ladle_ladle-postgres`,
`ladle_ladle-redis`, and `ladle_ladle-minio`), so moving from the earlier VPS
profile does not move or recreate application data.

## One-time host setup

Install Docker Engine with the Compose plugin, then create the bounded paths
and shared network:

```bash
sudo install -d -m 0755 /opt/ladle/app /var/backups/ladle
sudo install -d -m 0700 /opt/ladle/secrets
sudo docker network inspect platform-edge >/dev/null 2>&1 || \
  sudo docker network create platform-edge
sudo cp Backend/deploy/vps/env.example /opt/ladle/.env
sudo chmod 0600 /opt/ladle/.env
```

Replace every `change-me` value. Generate independent application, database,
Redis, metrics, encryption, and object-storage secrets with:

```bash
openssl rand -hex 32
```

Set `LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS` to the subnet reported by:

```bash
sudo docker network inspect platform-edge \
  --format '{{(index .IPAM.Config 0).Subnet}}'
```

## SSH rate limiting

The host refuses passwords outright (`passwordauthentication no`,
`kbdinteractiveauthentication no`, `permitrootlogin no`) and the `INPUT` policy
is `DROP` with an explicit allow chain for 22, 80 and 443, so the roughly 1,300
brute-force attempts a day the address attracts cannot succeed. `fail2ban` is
installed anyway, for log hygiene and defence in depth rather than to close a
hole: 9,500 junk auth lines a week make a real anomaly hard to see.

`/etc/fail2ban/jail.local` is not managed by `push.sh`; it is installed once by
hand. Two details in it matter:

- `banaction = iptables-multiport`, not the nftables default. Docker owns
  iptables on this host, and pointing fail2ban at nftables would put two things
  in charge of one firewall.
- `ignoreip` lists the operator's address and any other host that legitimately
  holds a key. A first ban is deliberately short (15 minutes, escalating to a
  day for repeat offenders) so a fumbled login from a new machine expires
  rather than stranding anyone.

Confirm bans are actually reachable after any firewall change — the jail's
chain has to be consulted *before* the allow chain, or it is inserted but never
matched:

```bash
sudo iptables -S INPUT | head -3     # f2b-sshd must precede LADLE_HOST_INPUT_A
sudo fail2ban-client status sshd
```

## OAuth setup

Every production deployment includes working Sign in with Apple and Google
OAuth configuration. The Compose profile sets both providers enabled and
refuses to start when their required values are absent or placeholders.

### Sign in with Apple and App Attest

In Apple Developer:

1. Register the `com.ladle.ios` App ID and enable Sign in with Apple and App
   Attest.
2. Create a Sign in with Apple key and download its `.p8` file once.
3. Install that file in `/opt/ladle/secrets/` for the container's fixed user:
   `sudo install -o 10001 -g 10001 -m 0400 AuthKey_KEYID.p8 /opt/ladle/secrets/`.
4. Set the App ID prefix, Team ID, Key ID, bundle ID, and absolute key path in
   `/opt/ladle/.env`.

The private key is mounted read-only at runtime; it is never stored in the
repository or copied into the container image. `LADLE_APPLE_BUNDLE_ID` and
`LADLE_APP_ATTEST_BUNDLE_ID` must both equal `com.ladle.ios`.

### Google OAuth

In Google Cloud Console:

1. Configure the OAuth consent screen.
2. Create an iOS OAuth client for bundle ID `com.ladle.ios`.
3. Create a Web application OAuth client for backend token verification.
4. Put the Web client ID in `LADLE_GOOGLE_SERVER_CLIENT_ID`.
5. Copy `Config/GoogleAuth.xcconfig.example` to
   `.private/GoogleAuth.xcconfig` and put the iOS and Web client IDs there.

The native SDK obtains the identity token, and the backend verifies its Web
client audience. There is no web callback route to configure.

Before launch, verify Apple, Google, account merge, refresh, and deletion on a
signed physical device. Provider secrets and tokens must never enter logs or
Git.

## Shared Caddy route

The shared gateway environment must already provide `LADLE_PUBLIC_HOSTNAME`
and `LADLE_TUNNEL_ACCESS_KEY`. After the new application is healthy, `push.sh`
installs the checked-in Ladle route into `/opt/platform/gateway/routes/`,
validates the complete Caddy configuration, and reloads it.

To validate and reload it manually:

```bash
cd /opt/platform/gateway
sudo docker compose --project-name platform-gateway \
  --env-file /etc/platform/gateway.env \
  exec gateway caddy validate --config /etc/caddy/Caddyfile
sudo docker compose --project-name platform-gateway \
  --env-file /etc/platform/gateway.env \
  exec gateway caddy reload --config /etc/caddy/Caddyfile
```

Only ports 22, 80, and 443 should be public. The Caddy route hides ordinary API
requests behind `X-Ladle-Tunnel-Key`; MinIO still validates its own signed
thumbnail URLs.

## Deploy and operate

From a clean local checkout, deploy `HEAD` or an explicit Git revision that
contains the simplified VPS profile:

```bash
Backend/deploy/vps/push.sh ubuntu@135.148.42.60
Backend/deploy/vps/push.sh ubuntu@135.148.42.60 <OLD_OR_NEW_GIT_SHA>
```

The script uploads a `git archive`, validates production configuration, builds
the application image, starts the data services, applies migrations, replaces
the API and worker, removes obsolete containers, checks API/worker health, and
then installs and reloads the shared Caddy route.

On the VPS:

```bash
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh status
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh health
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh logs 200
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh backup
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh backfill-times --dry-run
```

`backfill-times` is the one-off that gives recipes imported before the
estimating prompt a total cooking time. It runs in a throwaway `api`
container, so it carries the provider keys, and writes through the recipe
edit path so the estimate reaches devices on their next sync. Always run
`--dry-run` first and read the table; `--limit N` bounds a first pass.
`Backend/docs/integration-reference.md` documents the rules it applies.

## Operator dashboard

The VPS runs no Prometheus and no Grafana. It has neither the memory budget for
them nor a spare subdomain on its assigned hostname to terminate their TLS on,
so the API serves the dashboard itself at `/ops`, rendered in the browser from
the same Redis counters Prometheus would have scraped.

Add its credential to `/opt/ladle/.env` once, then redeploy:

```bash
printf 'LADLE_OPS_DASHBOARD_TOKEN=%s\n' "$(openssl rand -hex 32)" | \
    sudo tee -a /opt/ladle/.env >/dev/null
```

Production refuses to start without it, and refuses to let it equal
`LADLE_METRICS_AUTH_TOKEN`: the dashboard token is the only one that ever
reaches a browser. Open the dashboard once with the token in the query string:

```text
https://dashboard.overeasy.chetangoel.me/?token=<LADLE_OPS_DASHBOARD_TOKEN>
```

### Client certificates on the dashboard hostname

`dashboard.overeasy.chetangoel.me` requires a client certificate. Without one
the TLS handshake fails, so the name is unreachable rather than merely hidden,
and there is no credential to expire, leak into a log, or paste into a chat.
The API hostname keeps serving `/ops` with the token; that is the way back in
if a certificate is lost.

The certificate is the sign-in. Caddy verifies it, then overwrites
`X-Ladle-Ops-Client` with the peer's subject; the API hostname strips that
header so it can never arrive from a client. The application accepts a
non-empty value from a trusted proxy in place of the cookie, using the same
`LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS` list that decides whether
`X-Forwarded-For` is believable. So on this hostname there is no token to
paste and no session to expire.

The CA is private to this dashboard and lives in the repository's ignored
`.private/ops-mtls/`, which is also where its key stays so further devices can
be issued. Only `ops-ca.pem` — the public certificate — is copied to the host
at `/opt/platform/gateway/routes/ops-ca.pem`. `push.sh` does not manage that
file; it is installed once by hand. The `import` glob in the shared Caddyfile
matches `*.caddy`, so a `.pem` beside the routes is never parsed as config.

Issue a certificate for another device:

```bash
cd .private/ops-mtls
openssl ecparam -name prime256v1 -genkey -noout -out DEVICE.key
openssl req -new -key DEVICE.key -out DEVICE.csr -subj "/CN=DEVICE"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > ext.cnf
openssl x509 -req -in DEVICE.csr -CA ops-ca.pem -CAkey ops-ca.key -CAcreateserial \
    -out DEVICE.crt -days 730 -sha256 -extfile ext.cnf
openssl pkcs12 -export -legacy -out DEVICE.p12 -inkey DEVICE.key -in DEVICE.crt \
    -certfile ops-ca.pem -name "Overeasy Ops (DEVICE)" -passout pass:
```

Revoking one device means re-issuing the CA and every other certificate; with a
handful of devices that is cheaper than running a CRL or OCSP responder.

That name is a second site block in `deploy/vps/gateway/routes/ladle.caddy`,
installed by `push.sh` along with the API route. It needs a DNS `A` record at
Porkbun, where `chetangoel.me` is hosted, pointing
`dashboard.overeasy.chetangoel.me` at the VPS; Caddy provisions the certificate
by itself once that resolves. Override the name with
`LADLE_DASHBOARD_HOSTNAME` in `/etc/platform/gateway.env`, which has a default
so an unset variable cannot resolve to an empty site address and fail the
reload for every route in the file.

Only `/ops` answers on that hostname, and `/` rewrites to it so a pasted
`/?token=...` keeps its query. Auth, imports, sync, and the private object
store answer on `LADLE_PUBLIC_HOSTNAME` and nowhere else, so the name handed to
a browser cannot reach them. The API hostname still serves `/ops` too:

```text
https://<LADLE_PUBLIC_HOSTNAME>/ops?token=<LADLE_OPS_DASHBOARD_TOKEN>
```

The token moves into an HttpOnly, `SameSite=Lax` cookie scoped to `/` and good
for twelve hours; the address bar keeps only the path from then on.

Both attributes are deliberate. The cookie is **not** scoped to `/ops`: the
dashboard hostname rewrites `/` to `/ops` inside Caddy, so the browser's URL
stays `/`, and a `/ops`-scoped cookie would never be sent back — the one-time
handoff would appear to work and every later bookmark visit would 404. It is
**Lax** rather than Strict because Strict drops the cookie on any link opened
from chat or mail, which reads as the dashboard being broken; every dashboard
route is a read-only GET, so there is no state-changing request for Strict to
protect. The dedicated hostname, not the cookie path, is what keeps this
credential away from the API. Anything
without that cookie gets a 404, so the dashboard is invisible to public scans.
The shared Caddy route already proxies every path to `ladle-api`, so this needs
no gateway change.

The page shows requests by route, method, and status class, live requests per
minute, latency percentiles from the histogram buckets, import outcomes by
status and source, provider outcomes and billed units, cache and sync results,
rate-limit rejections by policy, and the queue, worker, and readiness gauges.
Counters are cumulative and survive restarts, so totals read "since the counters
were last reset," not "today"; the per-minute chart builds while the page is
open. Rotate the token by replacing the value and redeploying, which invalidates
every issued cookie. Rotate it also if it may have been recorded: the handoff
puts the token in a request target, so `--no-access-log` on the API command and
the `uvicorn.access` filter installed at import both exist to keep it out of
`docker logs`. Check with:

```bash
sudo sh -c 'T=$(grep "^LADLE_OPS_DASHBOARD_TOKEN=" /opt/ladle/.env | cut -d= -f2-); \
    docker logs ladle-api-1 2>&1 | grep -c -- "$T"'
```

## Backups

`manage.sh backup` creates and validates a custom-format PostgreSQL dump, a
compressed MinIO data archive, and a SHA-256 manifest. Local copies older than
14 days are removed. Copy backups off the VPS or use a host snapshot as a
second failure domain.

Install the nightly systemd timer:

```bash
sudo install -m 0644 Backend/deploy/vps/ladle-backup.service \
  Backend/deploy/vps/ladle-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ladle-backup.timer
sudo systemctl start ladle-backup.service
```

Periodically restore a dump into a temporary PostgreSQL database. A checksum
without a restore test proves file integrity, not recoverability.

## Rollback

The running containers keep the previous image if a build or configuration
check fails. To roll back an activated revision, rerun `push.sh` with the last
known-good Git SHA that contains this simplified profile. Do not reverse a
database migration until its downgrade and data compatibility have been
reviewed.

The legacy `/opt/ladle/releases` tree and its backups may remain during the
first simplified deployment as a recovery reference. Remove it only after the
new stack and backups have passed a deliberate rollback window.
