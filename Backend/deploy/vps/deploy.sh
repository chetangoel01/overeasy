#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Run deploy.sh as root." >&2
    exit 1
fi
if [ "$#" -ne 1 ]; then
    printf '%s\n' "Usage: deploy.sh FULL_GIT_COMMIT" >&2
    exit 1
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
deployment_library=$script_directory/deployment-lib.sh
if [ ! -f "$deployment_library" ] || [ -L "$deployment_library" ]; then
    printf '%s\n' "Missing deployment library." >&2
    exit 1
fi
. "$deployment_library"

revision=$1
validate_revision "$revision" || die "Deployment revision must be a full commit."
release="/opt/ladle/releases/$revision"
releases_directory=/opt/ladle/releases
if [ ! -d "$releases_directory" ] || [ -L "$releases_directory" ]; then
    die "The releases directory is unsafe."
fi
[ "$(readlink -f -- "$releases_directory")" = "$releases_directory" ] ||
    die "The releases directory path contains a symlink."
[ "$(stat -c "%u:%a" -- "$releases_directory")" = "0:755" ] ||
    die "The releases directory must be root-owned with mode 0755."

release_root_is_safe() {
    root_release=$1
    [ -d "$root_release" ] && [ ! -L "$root_release" ] || return 1
    [ "$(readlink -f -- "$root_release")" = "$root_release" ] || return 1
    [ "$(stat -c "%u:%a" -- "$root_release" | cut -d: -f1)" = 0 ] ||
        return 1
    if find "$root_release" -xdev \
        \( ! -user root -o -perm /022 \) -print -quit |
        grep -q .; then
        return 1
    fi
    for critical_path in \
        Backend/deploy/vps/initialize-env.sh \
        Backend/deploy/vps/deploy.sh \
        Backend/deploy/vps/deployment-lib.sh \
        Backend/docker-compose.yml \
        Backend/deploy/vps/docker-compose.yml; do
        [ -f "$root_release/$critical_path" ] &&
            [ ! -L "$root_release/$critical_path" ] || return 1
    done
    [ -x "$root_release/Backend/deploy/vps/initialize-env.sh" ] &&
        [ -x "$root_release/Backend/deploy/vps/deploy.sh" ] &&
        [ -x "$root_release/Backend/deploy/vps/deployment-lib.sh" ]
}

release_root_is_safe "$release" ||
    die "The exact release is missing, mutable, or unsafe."
revision_marker_matches "$release/.ladle-revision" "$revision" ||
    die "The release revision marker does not match."

backend_directory=$release/Backend
base_compose=$backend_directory/docker-compose.yml
vps_compose=$backend_directory/deploy/vps/docker-compose.yml
for release_file in "$base_compose" "$vps_compose"; do
    [ -f "$release_file" ] && [ ! -L "$release_file" ] ||
        die "The release is missing a required Compose file."
done

secret_group=ladle-secrets
env_file=/etc/ladle/ladle.env
validate_env_metadata "$env_file" "$secret_group" ||
    die "The staging environment metadata is unsafe."
validate_required_env "$env_file" \
    LADLE_PUBLIC_HOSTNAME \
    LADLE_DATABASE_PASSWORD \
    LADLE_DATABASE_PASSWORD_URL_ENCODED \
    LADLE_WORKER_PROVIDER_MODE \
    LADLE_JWT_SIGNING_SECRET \
    LADLE_DATA_ENCRYPTION_KEY \
    LADLE_METRICS_AUTH_TOKEN \
    LADLE_OBJECT_STORAGE_ACCESS_KEY \
    LADLE_OBJECT_STORAGE_SECRET_KEY \
    LADLE_TUNNEL_ACCESS_KEY ||
    die "The staging environment is incomplete or invalid."

provider_mode=$(dotenv_value "$env_file" LADLE_WORKER_PROVIDER_MODE) ||
    die "Cannot read worker provider mode."
case "$provider_mode" in
    fake) ;;
    live)
        dotenv_value "$env_file" LADLE_OPENROUTER_API_KEY >/dev/null ||
            die "Live provider mode requires an OpenRouter credential."
        ;;
    *) die "Worker provider mode must be fake or live." ;;
esac

progress_init "$secret_group"
deployment_phase=lock

finish_deployment() {
    status=$?
    if [ "$status" -ne 0 ]; then
        progress failure "$deployment_phase failed" || true
    fi
    trap - 0
    exit "$status"
}
trap finish_deployment 0
trap 'exit 1' HUP INT TERM

lock_file=/var/lock/ladle-deploy.lock
if [ -L "$lock_file" ]; then
    die "The deployment lock path is unsafe."
fi
if [ ! -e "$lock_file" ]; then
    install -o root -g root -m 0600 /dev/null "$lock_file"
fi
exec 9>"$lock_file"
flock -n 9 || die "Another Ladle deployment is running."

compose() {
    COMPOSE_PROJECT_NAME=ladle docker compose \
        --project-name ladle \
        --project-directory "$backend_directory" \
        --env-file "$env_file" \
        -f "$base_compose" \
        -f "$vps_compose" \
        "$@"
}

health_attempts=${LADLE_HEALTH_ATTEMPTS:-30}
case "$health_attempts" in
    "" | *[!0-9]*) die "LADLE_HEALTH_ATTEMPTS must be numeric." ;;
esac
[ "$health_attempts" -ge 1 ] && [ "$health_attempts" -le 120 ] ||
    die "LADLE_HEALTH_ATTEMPTS must be between 1 and 120."

wait_for_api_readiness() {
    readiness_attempt=1
    while [ "$readiness_attempt" -le "$health_attempts" ]; do
        if compose exec -T api /app/.venv/bin/python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:4111/health/ready', timeout=3)"; then
            return 0
        fi
        readiness_attempt=$((readiness_attempt + 1))
        sleep 2
    done
    return 1
}

wait_for_edge_readiness() {
    edge_attempt=1
    while [ "$edge_attempt" -le "$health_attempts" ]; do
        if compose exec -T api /app/.venv/bin/python -c \
            "import urllib.request; urllib.request.urlopen('http://edge:8082/health/ready', timeout=3)"; then
            return 0
        fi
        edge_attempt=$((edge_attempt + 1))
        sleep 2
    done
    return 1
}

wait_for_worker_ping() {
    worker_attempt=1
    while [ "$worker_attempt" -le "$health_attempts" ]; do
        if compose exec -T worker /app/.venv/bin/celery \
            -A ladle.worker.app:celery_app inspect ping --timeout=10; then
            return 0
        fi
        worker_attempt=$((worker_attempt + 1))
        sleep 2
    done
    return 1
}

deployment_phase=compose-validation
progress "compose-validation" "validating exact release configuration"
compose config --quiet

deployment_phase=data-services
progress "data-services" "starting private PostgreSQL Redis and object storage"
compose up -d --wait --wait-timeout 120 postgres redis minio

deployment_phase=image-build
progress "image-build" "building exact release images"
compose build migrate minio-init api worker beat worker-egress edge

deployment_phase=object-storage
progress "object-storage" "initializing the empty private bucket"
compose run --rm minio-init

deployment_phase=migrations
progress "migrations" "applying database migrations"
compose run --rm migrate

deployment_phase=service-rollout
progress "service-rollout" "replacing application services"
compose up -d --no-build --no-deps --wait --wait-timeout 120 worker-egress
compose up -d --no-build --no-deps --wait --wait-timeout 120 \
    --force-recreate worker
compose up -d --no-build --wait --wait-timeout 120 --no-deps api
compose up -d --no-build --no-deps beat
compose up -d --no-build --wait --wait-timeout 120 --no-deps edge
compose up -d --no-build --wait --wait-timeout 120 --no-deps caddy

deployment_phase=api-readiness
progress "api-readiness" "checking the local API readiness endpoint"
wait_for_api_readiness || die "The API readiness gate timed out."

deployment_phase=edge-readiness
progress "edge-readiness" "checking the internal edge request path"
wait_for_edge_readiness || die "The edge readiness gate timed out."

deployment_phase=worker-readiness
progress "worker-readiness" "checking the Celery worker response"
wait_for_worker_ping || die "The Celery worker gate timed out."

deployment_phase=activation
progress "activation" "activating revision $revision"
activate_release "$release" /opt/ladle/current ||
    die "The current release could not be activated."

deployment_phase=success
progress "success" "revision $revision is active"
