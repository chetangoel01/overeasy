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

Compose uses cheap runtime health checks: the API liveness endpoint runs every
30 seconds, and the Celery ping runs every five minutes. The explicit
`manage.sh health` command still checks full API readiness and worker response
before a deployment succeeds. Do not use full readiness as a frequent Docker
probe; it contacts every dependency and wakes a Celery CLI process even when
the application has no work.

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

## OAuth setup

Every production deployment includes working Sign in with Apple and Google
OAuth configuration. The Compose profile sets both providers enabled and
refuses to start when their required values are absent or placeholders.

### Sign in with Apple and App Attest

In Apple Developer:

1. Register the `com.ladle.ios` App ID and enable Sign in with Apple and App
   Attest.
2. Create a Sign in with Apple key and download its `.p8` file once.
3. Copy that file to `/opt/ladle/secrets/` with mode `0600`.
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
sudo docker compose exec gateway caddy validate --config /etc/caddy/Caddyfile
sudo docker compose exec gateway caddy reload --config /etc/caddy/Caddyfile
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
