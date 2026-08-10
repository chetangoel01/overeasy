#!/bin/sh
set -eu
umask 077

ladle_root=${LADLE_ROOT:-/opt/ladle}
backend=${LADLE_BACKEND_DIR:-$ladle_root/app/Backend}
env_file=${LADLE_ENV_FILE:-$ladle_root/.env}
backup_directory=${LADLE_BACKUP_DIR:-/var/backups/ladle}
profile=$backend/deploy/vps/docker-compose.yml

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ -f "$profile" ] || die "Missing VPS Compose profile at $profile"
[ -f "$env_file" ] || die "Missing deployment environment at $env_file"

compose() {
    docker compose \
        --project-name ladle \
        --project-directory "$backend" \
        --env-file "$env_file" \
        -f "$profile" \
        "$@"
}

health() {
    attempt=1
    while [ "$attempt" -le 30 ]; do
        if compose exec -T api /app/.venv/bin/python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:4111/health/ready', timeout=3)" \
            >/dev/null 2>&1 && \
            compose exec -T worker /app/.venv/bin/celery \
                -A ladle.worker.app:celery_app inspect ping --timeout=5 \
                >/dev/null 2>&1; then
            printf '%s\n' "Ladle API and worker are healthy."
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    compose ps
    die "Ladle did not become healthy."
}

deploy() {
    compose config --quiet
    compose build minio-init migrate api worker
    compose run --rm --no-deps api /app/.venv/bin/python -c \
        "from ladle.config import Settings; Settings()"
    compose up -d --wait postgres redis minio
    compose run --rm minio-init
    compose run --rm migrate
    compose up -d --remove-orphans api worker
    health
}

backup() {
    mkdir -p "$backup_directory"
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    database_backup=$backup_directory/ladle-postgres-$stamp.dump
    media_backup=$backup_directory/ladle-minio-$stamp.tar.gz
    manifest=$backup_directory/ladle-$stamp.sha256

    compose exec -T postgres pg_dump -U ladle -d ladle -Fc >"$database_backup"
    compose exec -T postgres pg_restore --list <"$database_backup" >/dev/null

    minio_container=$(compose ps -q minio)
    [ -n "$minio_container" ] || die "MinIO is not running."
    docker run --rm \
        --volumes-from "$minio_container" \
        -v "$backup_directory:/backup" \
        alpine:3.22 \
        tar -czf "/backup/$(basename "$media_backup")" -C /data .

    (
        cd "$backup_directory"
        sha256sum "$(basename "$database_backup")" "$(basename "$media_backup")" \
            >"$(basename "$manifest")"
        sha256sum --check "$(basename "$manifest")"
    )
    find "$backup_directory" -maxdepth 1 -type f \
        \( -name 'ladle-postgres-*' -o -name 'ladle-minio-*' -o -name 'ladle-*.sha256' \) \
        -mtime +14 -delete
    printf 'Backup written to %s\n' "$manifest"
}

command=${1:-}
case "$command" in
    deploy)
        deploy
        ;;
    health)
        health
        ;;
    status)
        compose ps
        ;;
    logs)
        lines=${2:-100}
        case "$lines" in
            '' | *[!0-9]*) die "Log line count must be numeric." ;;
        esac
        compose logs --tail "$lines" api worker postgres redis minio
        ;;
    backup)
        backup
        ;;
    *)
        die "Usage: manage.sh {deploy|health|status|logs [LINES]|backup}"
        ;;
esac
