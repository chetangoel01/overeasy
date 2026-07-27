#!/bin/sh
set -eu

umask 077
PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
export PATH

config_file=${LADLE_LOCAL_OPERATIONS_CONFIG:-$HOME/.config/ladle/local-operations.env}
if [ -f "$config_file" ]; then
    set -a
    . "$config_file"
    set +a
fi

support_dir=$HOME/Library/Application\ Support/Ladle
log_dir=$HOME/Library/Logs/Ladle
backup_dir=${LADLE_BACKUP_DIR:-$HOME/Backups/ladle}
log_file=$log_dir/local-operations.log
health_state=$support_dir/health.state
backup_state=$support_dir/backup.state
readiness_url=${LADLE_READINESS_URL:-http://127.0.0.1:4113/health/ready}
docker_context=${LADLE_DOCKER_CONTEXT:-desktop-linux}
postgres_container=${LADLE_POSTGRES_CONTAINER:-backend-postgres-1}
database_user=${LADLE_DATABASE_USER:-ladle}
database_name=${LADLE_DATABASE_NAME:-ladle}
backup_retention_days=${LADLE_BACKUP_RETENTION_DAYS:-35}
minimum_free_disk_gib=${LADLE_MINIMUM_FREE_DISK_GIB:-20}
expected_containers=${LADLE_EXPECTED_CONTAINERS:-"backend-postgres-1 backend-redis-1 backend-api-1 backend-worker-1 backend-beat-1 backend-worker-egress-1 backend-edge-1"}

for numeric_value in "$backup_retention_days" "$minimum_free_disk_gib"; do
    case $numeric_value in
        "" | *[!0-9]*)
            echo "Retention and disk thresholds must be nonnegative integers." >&2
            exit 1
            ;;
    esac
done

install -d -m 700 "$support_dir" "$log_dir" "$backup_dir"
touch "$log_file"
chmod 600 "$log_file"

if [ -x /usr/local/bin/docker ]; then
    docker_bin=/usr/local/bin/docker
elif [ -x /Applications/Docker.app/Contents/Resources/bin/docker ]; then
    docker_bin=/Applications/Docker.app/Contents/Resources/bin/docker
elif command -v docker >/dev/null 2>&1; then
    docker_bin=$(command -v docker)
else
    docker_bin=
fi

docker_cli() {
    if [ -z "$docker_bin" ]; then
        return 127
    fi
    "$docker_bin" --context "$docker_context" "$@"
}

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"
}

notify() {
    notification_title=$1
    notification_message=$2
    /usr/bin/osascript - "$notification_message" "$notification_title" \
        >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
}

read_state() {
    state_file=$1
    if [ -f "$state_file" ]; then
        /bin/cat "$state_file"
    else
        printf 'unknown\n'
    fi
}

write_state() {
    state_file=$1
    state_value=$2
    printf '%s\n' "$state_value" >"$state_file"
    chmod 600 "$state_file"
}

health_check() {
    failure=

    if ! /usr/bin/curl --fail --silent --show-error --max-time 10 \
        "$readiness_url" >/dev/null 2>&1; then
        failure="API readiness check failed"
    fi

    for container_name in $expected_containers; do
        container_state=$(
            docker_cli inspect \
                --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$container_name" 2>/dev/null || true
        )
        case $container_state in
            running\|healthy | running\|none) ;;
            *)
                failure="container $container_name is not ready"
                break
                ;;
        esac
    done

    free_disk_kib=$(/bin/df -Pk / | /usr/bin/awk 'NR == 2 {print $4}')
    minimum_free_disk_kib=$((minimum_free_disk_gib * 1024 * 1024))
    if [ "$free_disk_kib" -lt "$minimum_free_disk_kib" ]; then
        failure="free disk is below ${minimum_free_disk_gib} GiB"
    fi

    previous_state=$(read_state "$health_state")
    if [ -n "$failure" ]; then
        log "health failed: $failure"
        if [ "$previous_state" != failed ]; then
            notify "Ladle needs attention" "$failure"
        fi
        write_state "$health_state" failed
        return 1
    fi

    if [ "$previous_state" = failed ]; then
        log "health recovered"
        notify "Ladle recovered" "The API, containers, and disk checks are healthy again."
    elif [ "$previous_state" != healthy ]; then
        log "health monitoring enabled"
    fi
    write_state "$health_state" healthy
}

temporary_backup=

backup_failed() {
    failure_message=$1
    previous_state=$(read_state "$backup_state")
    log "backup failed: $failure_message"
    if [ "$previous_state" != failed ]; then
        notify "Ladle backup failed" "$failure_message"
    fi
    write_state "$backup_state" failed
    if [ -n "$temporary_backup" ] && [ -f "$temporary_backup" ]; then
        /bin/rm -f "$temporary_backup"
    fi
    exit 1
}

database_backup() {
    if ! health_check; then
        backup_failed "The local health check failed before backup."
    fi

    timestamp=$(date -u +%Y%m%d-%H%M%S)
    backup_name=ladle-$timestamp.dump
    backup_path=$backup_dir/$backup_name
    temporary_backup=$(/usr/bin/mktemp "$backup_dir/.ladle-backup.XXXXXX")

    if ! docker_cli exec "$postgres_container" \
        pg_dump -Fc -U "$database_user" "$database_name" >"$temporary_backup"; then
        backup_failed "PostgreSQL could not create the backup archive."
    fi
    if [ ! -s "$temporary_backup" ]; then
        backup_failed "PostgreSQL produced an empty backup archive."
    fi
    if ! docker_cli exec -i "$postgres_container" pg_restore --list \
        <"$temporary_backup" >/dev/null; then
        backup_failed "PostgreSQL could not validate the backup archive."
    fi

    chmod 600 "$temporary_backup"
    /bin/mv "$temporary_backup" "$backup_path"
    temporary_backup=
    (
        cd "$backup_dir"
        /usr/bin/shasum -a 256 "$backup_name" >"$backup_name.sha256"
        chmod 600 "$backup_name.sha256"
    )

    /usr/bin/find "$backup_dir" -type f \
        \( -name 'ladle-*.dump' -o -name 'ladle-*.dump.sha256' \) \
        -mtime "+$backup_retention_days" -delete

    previous_state=$(read_state "$backup_state")
    backup_size=$(/usr/bin/stat -f %z "$backup_path")
    log "backup ready: $backup_name ($backup_size bytes)"
    if [ "$previous_state" = failed ]; then
        notify "Ladle backup recovered" "A new validated database backup completed."
    elif [ "$previous_state" != healthy ]; then
        notify "Ladle backups enabled" "The first validated local database backup completed."
    fi
    write_state "$backup_state" healthy
}

case ${1:-} in
    health)
        health_check
        ;;
    backup)
        database_backup
        ;;
    *)
        echo "Usage: $0 {health|backup}" >&2
        exit 64
        ;;
esac
