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
ensure_secret LADLE_OBJECT_STORAGE_ACCESS_KEY
ensure_secret LADLE_OBJECT_STORAGE_SECRET_KEY

ensure_setting() {
    key=$1
    value=$2
    if ! grep -q "^${key}=" "$env_file"; then
        printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
}

ensure_setting LADLE_INSTALL_MEDIA_TOOLS false

set_setting() {
    key=$1
    value=$2
    temporary=$(mktemp "${env_file}.XXXXXX")
    grep -v "^${key}=" "$env_file" >"$temporary" || true
    printf '%s=%s\n' "$key" "$value" >>"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$env_file"
}

storage_public_url=${LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL:-}
if [ -z "$storage_public_url" ]; then
    storage_public_url=$(./deploy/mac-mini/ngrok.sh status 2>/dev/null || true)
fi
case $storage_public_url in
    https://*) ;;
    *)
        echo "Start the guarded ngrok route before deploying thumbnail storage." >&2
        exit 1
        ;;
esac
set_setting LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL "$storage_public_url"

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
compose up -d postgres redis minio
compose build migrate minio-init api worker beat worker-egress edge
compose run --rm minio-init
compose run --rm migrate
compose run --rm migrate /app/.venv/bin/python -m ladle.admin.cache_cli \
    backfill-thumbnails
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

"$tailscale_bin" serve reset
"$tailscale_bin" serve \
    --bg \
    --yes \
    --proxy-protocol=2 \
    --tls-terminated-tcp=443 \
    tcp://127.0.0.1:4112

compose ps
