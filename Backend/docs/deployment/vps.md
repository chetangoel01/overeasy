# OVH VPS staging operations

## Scope and selected host

This runbook deploys the guarded Ladle staging API to the new OVH VPS:

```text
Name: vps-8b0be574.vps.ovh.us
OS: Ubuntu 26.04
SSH user: ubuntu
IPv4: 135.148.42.60
IPv6: 2604:2dc0:121::64f
Public name: api.ladle.app
```

The staging decision is a fresh empty PostgreSQL database and empty object
store. Do not import the Mac mini database or object state. The profile keeps
`LADLE_ENVIRONMENT=development`, fake extraction at first, and the private
staging access gate. This is not production.

Commands are labeled **Mac** or **VPS**. Stop on an unexpected host fact,
fingerprint, failed gate, or missing backup; do not improvise around a
fail-closed script.

## Establish SSH access

The account owner opens the OVH one-time password link personally. Type that
password privately only at SSH password prompts used to bootstrap a dedicated
public key and retain lockout-recovery session A. Never put it in the
repository, chat, shell history, environment, clipboard automation, or command
arguments.

Create a dedicated key with a passphrase.

**Mac**

```bash
SSH_KEY="$HOME/.ssh/ladle-ovh-staging"
install -d -m 0700 "$HOME/.ssh"
ssh-keygen -t ed25519 -a 64 -f "$SSH_KEY" -C ladle-vps-staging
ssh-keygen -lf "$SSH_KEY.pub"
```

Before accepting the first SSH host key, open the VPS's OVH KVM console and
read its Ed25519 host-key fingerprint.

**VPS — OVH KVM console**

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare that complete fingerprint with the one SSH displays. Stop if they
differ. Only after they match, install the public key; `ssh-copy-id` prompts
for the one-time password without placing it in the command.

**Mac**

```bash
ssh-copy-id -i "$SSH_KEY.pub" ubuntu@135.148.42.60
```

Open an explicit password-authenticated recovery session after key
installation. Keep this password-authenticated session A open until hardening
and a post-hardening key-only login both succeed.

**Mac — retained session A**

```bash
ssh -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  ubuntu@135.148.42.60
```

Add a local SSH configuration entry for this address and the VPS hostname so
repository scripts use the dedicated identity:

```text
Host 135.148.42.60 vps-8b0be574.vps.ovh.us
    User ubuntu
    IdentityFile ~/.ssh/ladle-ovh-staging
    IdentitiesOnly yes
```

With session A still open, prove key-only access in a new session B before
provisioning or SSH hardening.

**Mac — new session B**

```bash
ssh -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  ubuntu@135.148.42.60
```

## Inspect, provision, and harden

First record the untouched host's release, architecture, memory, disk,
listening sockets, firewall rules, pending upgrades, and effective SSH policy.

**VPS**

```bash
cat /etc/os-release
dpkg --print-architecture
free -h
df -h
sudo ss -lntup
sudo iptables-save
sudo ip6tables-save
apt list --upgradable
sudo sshd -T
```

Transfer only the committed bootstrap inputs from a clean checkout.

**Mac — from `Backend/`**

```bash
ssh ubuntu@135.148.42.60 'install -d -m 0700 /tmp/ladle-vps-bootstrap'
scp \
  deploy/vps/provision.sh \
  deploy/vps/harden-ssh.sh \
  deploy/vps/host-validation.sh \
  deploy/vps/ladle-docker-user.rules \
  ubuntu@135.148.42.60:/tmp/ladle-vps-bootstrap/
```

**VPS — session A**

```bash
sudo /tmp/ladle-vps-bootstrap/provision.sh
```

If Ubuntu reports that a reboot is required, run `sudo reboot`; this closes
both SSH sessions. After any reboot, reopen and retain a fresh
password-authenticated session A:

**Mac — fresh retained session A**

```bash
ssh -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  ubuntu@135.148.42.60
```

Then prove a separate key-only session B before hardening:

**Mac — fresh key-only session B**

```bash
ssh -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  ubuntu@135.148.42.60
```

If no reboot was needed, keep the existing session A open and retain the
already-proven key-only session B. In session B, create the hardener's
root-owned assertion marker without exposing any credential.

**VPS — key-only session B**

```bash
printf '%s\n' 'LADLE_SSH_KEY_LOGIN_VERIFIED_V2 user=ubuntu' |
  sudo tee /run/ladle-key-login-marker >/dev/null
sudo chmod 0600 /run/ladle-key-login-marker
```

Run the committed hardener while session A is still open and preserves its
connection context.

**VPS — session A**

```bash
sudo --preserve-env=SSH_CONNECTION \
  /tmp/ladle-vps-bootstrap/harden-ssh.sh \
  /run/ladle-key-login-marker
```

Open one more key-only session before closing session A. Confirm that root and
password login are rejected. Keep OVH KVM available as the recovery console.

## DNS and first deployment

Create these DNS records with a short initial TTL:

```text
api.ladle.app A    135.148.42.60
api.ladle.app AAAA 2604:2dc0:121::64f
```

Check authoritative and public A/AAAA resolution before treating TLS as ready.
The deployment script requires a clean Git checkout and deploys exactly the
full commit at `HEAD`.

**Mac — from `Backend/`**

```bash
test -z "$(git status --porcelain --untracked-files=all)"
ssh ubuntu@135.148.42.60 'sudo -n true'
./deploy/vps/push.sh ubuntu@135.148.42.60
```

### Live setup feedback

`push.sh` emits fixed, sanitized phases in the Mac terminal. The VPS writes the
same server-side phases to `/var/log/ladle/setup.log`. During setup, a second
terminal can follow them live:

**Mac**

```bash
ssh -t ubuntu@135.148.42.60 \
  'until sudo test -f /var/log/ladle/setup.log; do sleep 1; done; sudo tail -F /var/log/ladle/setup.log'
```

These progress lines include only fixed phase names, bounded messages, and the
Git revision. Never stream secrets or environment values, and do not run
diagnostics that dump `/etc/ladle/ladle.env`. Stop the tail with `Ctrl-C`;
this does not stop deployment.

After the first successful push, install the health and backup operations from
that exact immutable release.

**Mac — from `Backend/`**

```bash
REVISION=$(git rev-parse --verify HEAD^{commit})
ssh ubuntu@135.148.42.60 \
  "sudo /opt/ladle/releases/$REVISION/Backend/deploy/vps/install-operations.sh $REVISION"
```

`systemd-analyze` is unavailable in the macOS workspace, and local tests do not
validate real systemd unit syntax. The Ubuntu-side `systemd-analyze verify` is
therefore mandatory before timers are enabled. The installer runs it against
staged unit copies whose `ExecStart` points to the staged operations binary,
before replacing live units or enabling either timer; any failure rolls the
transaction back. Then confirm the timers and guarded deployment.

**VPS**

```bash
sudo systemctl list-timers ladle-health.timer ladle-backup.timer
sudo ladle-operations status 80
sudo ladle-operations health
```

## Retrieve the staging key without printing it

Capture the root-readable staging key directly into an owner-only local file.
The redirection happens on the Mac, so the command never prints the key in the
terminal.

**Mac**

```bash
umask 077
STAGING_KEY_FILE="$HOME/.config/ladle/vps-staging-access-key"
install -d -m 0700 "$(dirname "$STAGING_KEY_FILE")"
ssh ubuntu@135.148.42.60 \
  'sudo cat /etc/ladle/staging-access-key' > "$STAGING_KEY_FILE"
chmod 0600 "$STAGING_KEY_FILE"
test -s "$STAGING_KEY_FILE"
```

Run the non-destructive guarded staging verifier.

**Mac — from `Backend/`**

```bash
uv run python scripts/verify_staging.py https://api.ladle.app \
  --staging-access-key-file "$STAGING_KEY_FILE"
```

The verifier checks TLS, security headers, rejection of missing or wrong
staging keys, readiness, hidden diagnostics, authentication, and request-size
handling. Keep the staging gate in place through the soak.

## Install or rotate provider credentials

Put a provider credential in a temporary owner-only file using a password
manager or another private local mechanism. Never show it with `cat`, pass it
as an argument, or export it. The repository-owned setter accepts the value
only through standard input and never logs it.

**Mac**

```bash
PROVIDER_SECRET_FILE="/absolute/path/to/private/provider-key"
test -f "$PROVIDER_SECRET_FILE"
test "$(stat -f '%Lp' "$PROVIDER_SECRET_FILE")" = 600
ssh ubuntu@135.148.42.60 \
  'sudo /opt/ladle/current/Backend/deploy/vps/set-secret.sh LADLE_OPENROUTER_API_KEY' \
  < "$PROVIDER_SECRET_FILE"
```

Installing `LADLE_OPENROUTER_API_KEY` atomically switches the worker provider
mode from fake to live. Redeploy the same clean revision, follow sanitized
progress, and rerun guarded verification before revoking an old provider key.
Supadata and SoScripted use their matching allowlisted key names.

## Routine status, logs, and backup

All commands are bounded and run as root on the VPS:

**VPS**

```bash
sudo ladle-operations status 80
sudo ladle-operations logs 80
sudo ladle-operations health
sudo ladle-operations backup
sudo journalctl --no-pager -u ladle-health.service -u ladle-backup.service -n 80
```

The nightly timer writes a custom-format PostgreSQL archive and SHA-256
sidecar under `/var/backups/ladle`, validates it with `pg_restore --list`, and
retains complete pairs for 35 days. Keep at least 20 GiB free.

OVH snapshots are not database-aware backups. The local dump protects against
some application and database mistakes, but neither it nor an OVH snapshot
protects against loss of the VPS account or region. Copy validated archives to
independent, encrypted, access-controlled off-host storage before production.

## Empty-server PostgreSQL 16 restore drill

This drill restores a chosen validated archive into a disposable, isolated,
empty PostgreSQL 16 container. It never targets the live `ladle-postgres`
volume. Replace `<BACKUP_FILE>` with the filename reported by
`ladle-operations backup`.

**VPS**

```bash
BACKUP="/var/backups/ladle/<BACKUP_FILE>"
sudo sh -c \
  'cd /var/backups/ladle && sha256sum --check --strict "$(basename "$1").sha256"' \
  sh "$BACKUP"

sudo docker run --detach --name ladle-restore-drill \
  --network none \
  --tmpfs /var/lib/postgresql/data:rw,nosuid,nodev,size=2g \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16
for attempt in $(seq 1 60)
do
  sudo docker exec ladle-restore-drill pg_isready --username postgres && break
  sleep 1
done
sudo docker exec ladle-restore-drill pg_isready --username postgres
sudo sh -c \
  'docker exec -i ladle-restore-drill pg_restore --list < "$1" >/dev/null' \
  sh "$BACKUP"
sudo sh -c \
  'docker exec -i ladle-restore-drill pg_restore --exit-on-error --no-owner --no-privileges --username postgres --dbname postgres < "$1"' \
  sh "$BACKUP"
sudo docker exec ladle-restore-drill \
  psql --username postgres --dbname postgres --tuples-only --command \
  'SELECT version_num FROM alembic_version; SELECT count(*) FROM users; SELECT count(*) FROM recipes;'
sudo docker rm --force --volumes ladle-restore-drill
```

Record the archive filename, verified digest, schema revision, expected row
counts, and cleanup result without recording data or credentials. A live
restore requires a separate approved outage plan and an empty replacement
database; never overwrite the active named volume in place.

## Deterministic rollback

Rollback means redeploying one named, immutable, previously verified full
commit. Confirm that its application remains compatible with the current
forward-migrated schema. Do not run an improvised Alembic downgrade.

If the release already exists on the VPS:

**VPS**

```bash
ROLLBACK_REVISION="<FULL_COMMIT>"
sudo "/opt/ladle/releases/$ROLLBACK_REVISION/Backend/deploy/vps/deploy.sh" \
  "$ROLLBACK_REVISION"
sudo ladle-operations health
```

If it is not present, create a separate clean detached worktree and use the
normal exact-release push path.

**Mac — from the repository root**

```bash
ROLLBACK_REVISION="<FULL_COMMIT>"
git worktree add --detach ../ladle-vps-rollback "$ROLLBACK_REVISION"
cd ../ladle-vps-rollback/Backend
./deploy/vps/push.sh ubuntu@135.148.42.60
```

Follow `/var/log/ladle/setup.log`, rerun the guarded verifier, and remove the
temporary local worktree only after recording the result. If schema
compatibility is uncertain, stop and restore the selected backup into a new
empty PostgreSQL service instead of changing the live database.

## SSH key rotation

Key rotation overlaps old and new access:

1. Generate a new dedicated Ed25519 key on the Mac.
2. From the still-working old-key session, install only the new public key.
3. Prove a second key-only login using the new identity and compare public-key
   fingerprints.
4. Remove the old public key from `~ubuntu/.ssh/authorized_keys`.
5. Prove the old key fails and the new key succeeds before closing recovery
   sessions.

**Mac**

```bash
NEW_SSH_KEY="$HOME/.ssh/ladle-ovh-staging-next"
ssh-keygen -t ed25519 -a 64 -f "$NEW_SSH_KEY" -C ladle-vps-staging-next
ssh-copy-id -i "$NEW_SSH_KEY.pub" ubuntu@135.148.42.60
ssh -i "$NEW_SSH_KEY" -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  ubuntu@135.148.42.60
```

Use `ssh-keygen -lf ~ubuntu/.ssh/authorized_keys` on the VPS to identify public
keys by fingerprint. Back up the public-key list, edit out only the old
fingerprint's line, and preserve its mode:

**VPS**

```bash
cp -p ~/.ssh/authorized_keys ~/.ssh/authorized_keys.before-key-rotation
ssh-keygen -lf ~/.ssh/authorized_keys
${EDITOR:-vi} ~/.ssh/authorized_keys
chmod 0600 ~/.ssh/authorized_keys
```

Never copy a private key to the server.

## Production promotion blockers

Do not remove the staging gate or set `LADLE_ENVIRONMENT=production` as part of
this runbook. A separate reviewed production plan must first prove:

- an external PostgreSQL restore and off-provider, point-in-time-capable
  database backups;
- versioned, encrypted off-host object state with lifecycle and restore tests;
- TLS-credentialed PostgreSQL and Redis data services with rotation and
  failover;
- production Apple sign-in and Google sign-in configuration;
- App Attest enforcement, replay controls, and real-device checks on a signed
  distribution build;
- external tracing, alert delivery, and actionable dashboards;
- provider and application key rotation drills; and
- a reviewed public-ingress change to remove the staging gate only after all
  other production gates pass.

Record a staging soak, live import journeys, restart recovery, validated
off-host backups, and the isolated restore drill before starting that design.

## Verification record

For each rollout, record the exact revision, redacted host facts, DNS and TLS
results, firewall exposure, timer state, container health, guarded verifier
result, backup name/digest, restore outcome, and known limitations. Never
record passwords, tokens, provider values, staging keys, signed URLs, complete
environment files, or provider response bodies.

## Repository change record

This runbook is the companion document for the VPS staging operations path. It
records the operator-visible workflow and live feedback, the empty-state and
development-only decisions, recovery boundaries, and production blockers.
Affected components are `deploy/vps/`, `scripts/verify_staging.py`, this
runbook, and the deployment links in both READMEs.

Repository verification is:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
./scripts/check_secrets.sh
git diff --check
```

These checks validate documentation contracts and committed artifacts; they do
not certify a live VPS. Creating this runbook performs no SSH, DNS, credential,
backup, container, or external-state action.
