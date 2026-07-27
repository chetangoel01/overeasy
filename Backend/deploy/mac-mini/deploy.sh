#!/bin/sh
set -eu

umask 077
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

if command -v docker >/dev/null 2>&1; then
    docker_bin=$(command -v docker)
elif [ -x "$HOME/.orbstack/bin/docker" ]; then
    docker_bin=$HOME/.orbstack/bin/docker
else
    echo "Docker or OrbStack is required." >&2
    exit 1
fi

compose() {
    "$docker_bin" compose \
        --env-file "$env_file" \
        -f docker-compose.yml \
        -f deploy/mac-mini/docker-compose.yml \
        "$@"
}

compose config >/dev/null
compose up -d postgres redis minio
compose run --rm minio-init
compose build migrate api worker beat
compose run --rm migrate
compose up -d --no-build --no-deps api worker beat

curl \
    --fail \
    --retry 30 \
    --retry-all-errors \
    --retry-delay 2 \
    http://127.0.0.1:4112/health/ready
printf '\n'
compose ps
