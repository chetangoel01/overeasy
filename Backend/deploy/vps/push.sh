#!/bin/sh
set -eu
umask 077

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "Usage: push.sh SSH_USER@HOST [GIT_REVISION]"
fi

ssh_target=$1
revision=${2:-HEAD}
case "$ssh_target" in
    "" | -* | *[!A-Za-z0-9_.@:-]* | *@*@* | @* | *@)
        die "SSH target is unsafe or lacks an explicit user."
        ;;
esac

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository=$(git -C "$script_directory" rev-parse --show-toplevel)
revision=$(git -C "$repository" rev-parse --verify "$revision^{commit}")
case "$revision" in
    *[!0-9a-f]*) die "Git did not resolve a full commit SHA." ;;
esac
[ "${#revision}" -eq 40 ] || die "Git did not resolve a full commit SHA."
git -C "$repository" cat-file -e \
    "$revision:Backend/deploy/vps/manage.sh" 2>/dev/null ||
    die "Revision predates the simplified VPS deployment profile."
archive=$(mktemp /tmp/ladle-release.XXXXXX.tar.gz)
remote_archive=/tmp/ladle-release-$revision.tar.gz

cleanup() {
    rm -f -- "$archive"
    ssh "$ssh_target" "rm -f -- '$remote_archive'" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

git -C "$repository" archive --format=tar.gz -o "$archive" "$revision"
scp "$archive" "$ssh_target:$remote_archive"

ssh "$ssh_target" sh -s -- "$remote_archive" "$revision" <<'REMOTE'
set -eu
archive=$1
revision=$2
app=/opt/ladle/app
gateway=/opt/platform/gateway
gateway_env=/etc/platform/gateway.env

sudo -n test -f /opt/ladle/.env
sudo -n test -f "$gateway/docker-compose.yml"
sudo -n test -f "$gateway_env"
sudo -n test -d "$gateway/routes"
sudo -n mkdir -p "$app"
sudo -n find "$app" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
sudo -n tar -xzf "$archive" -C "$app"
sudo -n sh -c "printf '%s\n' '$revision' > '$app/.ladle-revision'"
rm -f -- "$archive"
sudo -n /opt/ladle/app/Backend/deploy/vps/manage.sh deploy
sudo -n install -m 0644 \
    "$app/Backend/deploy/vps/gateway/routes/ladle.caddy" \
    "$gateway/routes/ladle.caddy"
sudo -n sh -c "cd '$gateway' && docker compose --project-name platform-gateway --env-file /etc/platform/gateway.env exec -T gateway caddy validate --config /etc/caddy/Caddyfile && docker compose --project-name platform-gateway --env-file /etc/platform/gateway.env exec -T gateway caddy reload --config /etc/caddy/Caddyfile"

# The route file above is the only thing that tells the gateway which
# hostnames to answer, and it replaces whatever was there. A revision whose
# route lists fewer names than the one it replaced silently drops a hostname:
# the certificate stays on disk, the API keeps minting signed media URLs for
# it, and every client on that name fails at the TLS handshake (2026-09-18).
# So the deploy is not finished until every hostname the app can be pointed
# at answers over TLS: the canonical domain and the gateway's alias.
alias_hostname=$(sudo -n sh -c ". '$gateway_env' && printf '%s' \"\${LADLE_PUBLIC_HOSTNAME:-}\"")
for hostname in api.overeasy.chetangoel.me $alias_hostname; do
    attempt=0
    until curl -fsS --max-time 15 -o /dev/null "https://$hostname/health/ready"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 6 ]; then
            printf 'Gateway does not answer https://%s/health/ready after deploy.\n' \
                "$hostname" >&2
            exit 1
        fi
        sleep 5
    done
    printf 'Ready: https://%s\n' "$hostname"
done
REMOTE

printf 'Deployed %s to %s\n' "$revision" "$ssh_target"
