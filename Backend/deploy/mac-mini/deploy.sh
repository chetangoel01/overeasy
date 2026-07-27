#!/bin/sh
set -eu

umask 077
PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:$PATH"
export PATH

backend_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$backend_dir"

env_file=${LADLE_MAC_MINI_ENV_FILE:-.env.mac-mini}
if [ ! -f "$env_file" ]; then
    install -m 600 /dev/null "$env_file"
fi
chmod 600 "$env_file"

ensure_secret() {
    key=$1
    if ! grep -q "^${key}=" "$env_file"; then
        value=$(openssl rand -hex 32)
        printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
}

ensure_secret LADLE_JWT_SIGNING_SECRET
ensure_secret LADLE_DATA_ENCRYPTION_KEY
ensure_secret LADLE_METRICS_AUTH_TOKEN

ensure_setting() {
    key=$1
    value=$2
    if ! grep -q "^${key}=" "$env_file"; then
        printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
}

ensure_setting LADLE_INSTALL_MEDIA_TOOLS false

if command -v docker >/dev/null 2>&1; then
    docker_bin=$(command -v docker)
elif [ -x "$HOME/.orbstack/bin/docker" ]; then
    docker_bin=$HOME/.orbstack/bin/docker
else
    echo "Docker or OrbStack is required." >&2
    exit 1
fi

compose() {
    if [ -n "${LADLE_MAC_MINI_DOCKER_CONTEXT:-}" ]; then
        "$docker_bin" --context "$LADLE_MAC_MINI_DOCKER_CONTEXT" compose \
            --env-file "$env_file" \
            -f docker-compose.yml \
            -f deploy/mac-mini/docker-compose.yml \
            "$@"
        return
    fi
    "$docker_bin" compose \
        --env-file "$env_file" \
        -f docker-compose.yml \
        -f deploy/mac-mini/docker-compose.yml \
        "$@"
}

compose config >/dev/null
compose stop minio || true
compose up -d postgres redis
compose pull edge
compose build migrate minio-init api worker beat worker-egress
compose run --rm migrate
compose up \
    -d \
    --no-build \
    --no-deps \
    --wait \
    --wait-timeout 60 \
    worker-egress
compose up -d --no-build --no-deps api beat
compose up -d --no-build --no-deps --force-recreate worker
compose up -d --no-build --no-deps edge

curl \
    --fail \
    --retry 30 \
    --retry-all-errors \
    --retry-delay 2 \
    http://127.0.0.1:4113/health/ready
printf '\n'

if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    tailscale_bin=/Applications/Tailscale.app/Contents/MacOS/Tailscale
elif command -v tailscale >/dev/null 2>&1; then
    tailscale_bin=$(command -v tailscale)
else
    echo "Tailscale is required for the private ingress." >&2
    exit 1
fi

"$tailscale_bin" serve \
    --bg \
    --yes \
    --proxy-protocol=2 \
    --tls-terminated-tcp=443 \
    tcp://127.0.0.1:4112

compose ps
