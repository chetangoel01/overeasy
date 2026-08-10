# Backend simplification verification

## Purpose and result

The VPS deployment was reduced to the smallest production shape that should
comfortably serve Ladle's first roughly 100 users. Five containers remain
running: two Uvicorn API processes, one Celery worker with four import slots and
the embedded Beat scheduler, PostgreSQL, Redis, and MinIO. Migrations and bucket
initialization are one-shot jobs. Shared Caddy is the only public listener.

The VPS operations surface is now two shell scripts totaling 179 lines instead
of the previous 5,546-line private control plane. The 9,186-line deployment
profile test was replaced by focused contract tests. Kubernetes manifests,
managed multi-AZ/PITR policy, a privileged egress sidecar, a second Ladle edge
proxy, and the custom operations launcher were removed because none solves a
current need at this scale.

## OAuth and security decisions

Production Compose enables Apple and Google sign-in unconditionally. Startup
fails closed without the Apple team ID, key ID, mounted `.p8` private key,
matching App Attest identity, and Google server OAuth client ID. The Apple key
is mounted read-only and never enters the image or repository.

PostgreSQL, passworded Redis, and MinIO may use plaintext protocols only on
their exact private Compose hostnames. External endpoints still require TLS.
User-controlled media requests retain the application's DNS pinning and SSRF
checks; the removed privileged firewall sidecar did not justify its operational
cost on this single-tenant host.

## Affected components

- `Backend/deploy/vps/`: standalone Compose profile, environment contract,
  deployment, health, logs, backup, and shared Caddy route.
- `Backend/ladle/config.py` and `Backend/ladle/api/app.py`: mounted Apple key and
  single-host production dependency rules.
- Deployment, operations, startup, security, architecture, and README docs.
- Focused VPS, migration, data-service, configuration, Apple, and Google tests.

## Verification

- Focused deployment/config/auth tests: 110 passed. Complete non-live/non-chaos
  backend suite: 502 passed and 5 credential-dependent tests deselected.
- Shell syntax, Compose interpolation, Ruff on changed Python, strict mypy on
  changed modules, and `git diff --check`: passed.
- Caddy 2.11.4 validation: passed.
- Two isolated production-shaped Compose deployments: passed. Each built the
  image, validated production OAuth/App Attest settings, migrated PostgreSQL
  through revision `0012`, started all five containers, and passed API and
  Celery health checks.
- Backup smoke: passed. PostgreSQL custom dump and MinIO archive were created,
  independently listed/hashed, and the disposable stack was removed cleanly.
- Independent PostgreSQL 16.14 restore drill: two rows restored with identical
  source and destination SHA-256 checksums.
- Full-history high-confidence secret scan: passed.
- Dependency audit: passed after upgrading `cryptography` to the fixed 50.x
  release for `PYSEC-2026-3552`.

The live VPS was intentionally not changed during this verification. Its old
stack is healthy, but its environment has no Apple OAuth, Google OAuth, or App
Attest credentials. The simplified production profile correctly refuses that
incomplete configuration; promotion waits for those provider values and a
signed-device login check.
