#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

env_file=/etc/ladle/ladle.env
current_release=/opt/ladle/current
deployment_state=/var/lib/ladle/deployment-state
operations_state=/var/lib/ladle/operations
backup_dir=/var/backups/ladle
operations_log=/var/log/ladle/operations.log
deployment_lock=/var/lib/ladle/locks/deploy.lock
backup_retention_days=35
minimum_free_disk_gib=20
backup_max_age_hours=36
certificate_minimum_seconds=604800
temporary_backup=
temporary_checksum=
backup_path=
checksum_path=
backup_published=false
checksum_published=false
backend_directory=
base_compose=
vps_compose=
runtime_paths_ready=false

fail() {
    printf '%s\n' "$*" >&2
    return 1
}

safe_regular_file() {
    safe_file=$1
    safe_mode=$2
    [ -f "$safe_file" ] && [ ! -L "$safe_file" ] || return 1
    [ "$(stat -c '%u:%a' -- "$safe_file")" = "0:$safe_mode" ]
}

safe_directory() {
    safe_path=$1
    safe_mode=$2
    [ -d "$safe_path" ] && [ ! -L "$safe_path" ] || return 1
    [ "$(readlink -f -- "$safe_path")" = "$safe_path" ] || return 1
    [ "$(stat -c '%u:%a' -- "$safe_path")" = "0:$safe_mode" ]
}

validate_revision() {
    candidate_revision=$1
    [ "${#candidate_revision}" -eq 40 ] || return 1
    case "$candidate_revision" in
        *[!0-9a-f]*) return 1 ;;
    esac
}

validate_runtime_paths() {
    runtime_paths_ready=false
    safe_directory "$operations_state" 700 || {
        fail "Operations state directory metadata is unsafe."
        return 1
    }
    safe_directory /var/lib/ladle/locks 700 || {
        fail "Operations lock directory metadata is unsafe."
        return 1
    }
    safe_directory "$backup_dir" 700 || {
        fail "Backup directory metadata is unsafe."
        return 1
    }
    safe_directory /var/log/ladle 750 || {
        fail "Operations log directory metadata is unsafe."
        return 1
    }
    secret_group_id=$(
        getent group ladle-secrets | awk -F: 'NR == 1 { print $3 }'
    )
    [ -n "$secret_group_id" ] || {
        fail "The Ladle secrets group is missing."
        return 1
    }
    [ "$(stat -c '%u:%g:%a' -- "$operations_log" 2>/dev/null || true)" = \
        "0:$secret_group_id:640" ] || {
        fail "Operations log metadata is unsafe."
        return 1
    }
    [ "$(stat -c '%u:%g:%a' -- "$env_file" 2>/dev/null || true)" = \
        "0:$secret_group_id:640" ] || {
        fail "Staging environment metadata is unsafe."
        return 1
    }
    [ ! -L "$operations_log" ] && [ ! -L "$env_file" ] || {
        fail "A secret-bearing path is a symlink."
        return 1
    }
    runtime_paths_ready=true
}

load_authoritative_release() {
    safe_regular_file "$deployment_state" 644 || {
        fail "Deployment state metadata is unsafe."
        return 1
    }
    [ "$(wc -l <"$deployment_state" | tr -d ' ')" = 3 ] || {
        fail "Deployment state has an invalid shape."
        return 1
    }

    status_line=$(sed -n '1p' "$deployment_state")
    revision_line=$(sed -n '2p' "$deployment_state")
    phase_line=$(sed -n '3p' "$deployment_state")
    [ "$status_line" = "STATUS=active" ] || {
        fail "Deployment state is not active."
        return 1
    }
    [ "$phase_line" = "PHASE=complete" ] || {
        fail "Deployment state is not complete."
        return 1
    }
    revision=${revision_line#REVISION=}
    [ "$revision_line" = "REVISION=$revision" ] &&
        validate_revision "$revision" || {
        fail "Deployment state has an invalid revision."
        return 1
    }

    [ -L "$current_release" ] || {
        fail "Current release is not an atomic symlink."
        return 1
    }
    resolved_release=$(readlink -f -- "$current_release") || {
        fail "Cannot resolve the current release."
        return 1
    }
    [ "$resolved_release" = "/opt/ladle/releases/$revision" ] || {
        fail "Deployment state and current release are mixed."
        return 1
    }
    safe_directory "$resolved_release" 755 || {
        fail "The active release metadata is unsafe."
        return 1
    }
    revision_marker=$resolved_release/.ladle-revision
    safe_regular_file "$revision_marker" 444 || {
        fail "The active revision marker metadata is unsafe."
        return 1
    }
    [ "$(cat "$revision_marker")" = "$revision" ] || {
        fail "The active revision marker does not match."
        return 1
    }

    backend_directory=$resolved_release/Backend
    base_compose=$backend_directory/docker-compose.yml
    vps_compose=$backend_directory/deploy/vps/docker-compose.yml
    safe_regular_file "$base_compose" 644 || {
        fail "The active base Compose file is unsafe."
        return 1
    }
    safe_regular_file "$vps_compose" 644 || {
        fail "The active VPS Compose file is unsafe."
        return 1
    }
}

compose() {
    COMPOSE_PROJECT_NAME=ladle docker compose \
        --project-name ladle \
        --project-directory "$backend_directory" \
        --env-file "$env_file" \
        -f "$base_compose" \
        -f "$vps_compose" \
        "$@"
}

acquire_deployment_lock() {
    safe_regular_file "$deployment_lock" 600 || {
        fail "Deployment lock metadata is unsafe."
        return 1
    }
    exec 9>"$deployment_lock"
    flock -n 9 || {
        fail "A deployment is running; backup was not started."
        return 1
    }
    safe_regular_file "$deployment_lock" 600 || {
        fail "Deployment lock metadata changed."
        return 1
    }
}

read_transition_state() {
    transition_file=$1
    if safe_regular_file "$transition_file" 600; then
        cat "$transition_file"
    else
        printf '%s\n' unknown
    fi
}

write_transition_state() {
    transition_file=$1
    transition_value=$2
    transition_tmp=$(mktemp "$operations_state/.transition.XXXXXX") ||
        return 1
    if ! printf '%s\n' "$transition_value" >"$transition_tmp" ||
        ! chmod 0600 "$transition_tmp" ||
        ! mv -f -- "$transition_tmp" "$transition_file"; then
        rm -f -- "$transition_tmp" || true
        return 1
    fi
}

log_transition() {
    transition_kind=$1
    transition_state=$2
    transition_message=$3
    transition_file=$operations_state/$transition_kind.state
    previous_transition=$(read_transition_state "$transition_file")
    [ "$previous_transition" = "$transition_state" ] && return 0
    write_transition_state "$transition_file" "$transition_state" ||
        return 1
    if ! printf '%s %s %s: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$transition_kind" "$transition_state" "$transition_message" \
        >>"$operations_log"; then
        if [ "$previous_transition" = unknown ]; then
            rm -f -- "$transition_file" || true
        else
            write_transition_state \
                "$transition_file" "$previous_transition" || true
        fi
        return 1
    fi
    # Staging records state transitions locally. Production requires an
    # external notification destination before promotion.
}

append_failure() {
    failed_check=$1
    if [ -n "${health_failures:-}" ]; then
        health_failures="$health_failures, $failed_check"
    else
        health_failures=$failed_check
    fi
}

container_is_ready() {
    container_service=$1
    container_id=$(compose ps -q "$container_service" 2>/dev/null) || return 1
    [ -n "$container_id" ] || return 1
    container_state=$(
        docker inspect \
            --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$container_id" 2>/dev/null
    ) || return 1
    case "$container_state" in
        true\|healthy | true\|none) return 0 ;;
        *) return 1 ;;
    esac
}

check_containers() {
    for runtime_service in \
        caddy edge api worker beat postgres redis minio; do
        if ! container_is_ready "$runtime_service"; then
            append_failure "$runtime_service container"
        fi
    done
}

check_caddy() {
    if ! compose exec -T caddy caddy validate \
        --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        append_failure "Caddy"
    fi
}

check_nginx() {
    if ! compose exec -T edge nginx -t >/dev/null 2>&1; then
        append_failure "Nginx edge"
    fi
}

check_api() {
    if ! compose exec -T api /app/.venv/bin/python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:4111/health/ready', timeout=5)" \
        >/dev/null 2>&1; then
        append_failure "API readiness"
    fi
}

check_worker() {
    if ! compose exec -T worker /app/.venv/bin/celery \
        -A ladle.worker.app:celery_app inspect ping --timeout=10 \
        >/dev/null 2>&1; then
        append_failure "worker ping"
    fi
}

check_postgres() {
    if ! compose exec -T postgres pg_isready -U ladle -d ladle \
        >/dev/null 2>&1; then
        append_failure "PostgreSQL"
    fi
}

check_redis() {
    if ! compose exec -T redis redis-cli ping 2>/dev/null |
        grep -Fx PONG >/dev/null; then
        append_failure "Redis"
    fi
}

check_minio() {
    if ! compose exec -T api /app/.venv/bin/python -c \
        "import urllib.request; urllib.request.urlopen('http://minio:9000/minio/health/live', timeout=5)" \
        >/dev/null 2>&1; then
        append_failure "MinIO"
    fi
}

public_hostname() {
    hostname_value=$(
        awk -F= '
            $1 == "LADLE_PUBLIC_HOSTNAME" {
                found++
                print substr($0, length($1) + 2)
            }
            END { exit found != 1 }
        ' "$env_file"
    ) || return 1
    case "$hostname_value" in
        "" | *[!A-Za-z0-9.-]* | .* | *..* | *.) return 1 ;;
    esac
    printf '%s\n' "$hostname_value"
}

check_certificate() {
    certificate_hostname=$(public_hostname) || {
        append_failure "certificate hostname"
        return
    }
    if ! timeout 15 openssl s_client \
        -connect 127.0.0.1:443 \
        -servername "$certificate_hostname" </dev/null 2>/dev/null |
        openssl x509 -checkend "$certificate_minimum_seconds" -noout \
            >/dev/null 2>&1; then
        append_failure "certificate expiry"
    fi
}

latest_backup_path() {
    find "$backup_dir" -maxdepth 1 -type f -name 'ladle-*.dump' \
        -printf '%T@ %p\n' |
        sort -rn |
        awk 'NR == 1 { print $2 }'
}

check_backup_freshness() {
    latest_backup=$(latest_backup_path)
    if [ -z "$latest_backup" ]; then
        append_failure "backup is stale"
        return
    fi
    latest_checksum=$latest_backup.sha256
    if ! safe_regular_file "$latest_backup" 600 ||
        ! safe_regular_file "$latest_checksum" 600; then
        append_failure "backup is stale"
        return
    fi
    backup_age_seconds=$((
        $(date +%s) - $(stat -c '%Y' -- "$latest_backup")
    ))
    if [ "$backup_age_seconds" -lt 0 ] ||
        [ "$backup_age_seconds" -gt $((backup_max_age_hours * 3600)) ]; then
        append_failure "backup is stale"
        return
    fi
    if ! (
        cd "$backup_dir"
        sha256sum -c --status "$(basename -- "$latest_checksum")"
    ); then
        append_failure "backup checksum"
    fi
}

health_check() {
    health_failures=
    if ! validate_runtime_paths || ! load_authoritative_release; then
        health_failures="deployment authority"
    else
        check_containers
        check_caddy
        check_nginx
        check_api
        check_worker
        check_postgres
        check_redis
        check_minio
        check_certificate
        check_backup_freshness
    fi

    if [ -n "$health_failures" ]; then
        if [ "$runtime_paths_ready" = true ]; then
            log_transition health failed "$health_failures" || true
        fi
        printf 'health failed: %s\n' "$health_failures" >&2
        return 1
    fi
    log_transition health healthy "all checks passed"
    printf '%s\n' "health healthy"
}

cleanup_backup() {
    cleanup_status=0
    if [ -n "$temporary_backup" ] && [ -f "$temporary_backup" ]; then
        rm -f -- "$temporary_backup" || cleanup_status=1
    fi
    if [ -n "$temporary_checksum" ] && [ -f "$temporary_checksum" ]; then
        rm -f -- "$temporary_checksum" || cleanup_status=1
    fi
    if [ "$backup_published" != "$checksum_published" ]; then
        if [ "$backup_published" = true ] && [ -n "$backup_path" ]; then
            if rm -f -- "$backup_path"; then
                backup_published=false
            else
                cleanup_status=1
            fi
        fi
        if [ "$checksum_published" = true ] && [ -n "$checksum_path" ]; then
            if rm -f -- "$checksum_path"; then
                checksum_published=false
            else
                cleanup_status=1
            fi
        fi
    fi
    [ "$cleanup_status" -eq 0 ]
}

database_backup() {
    temporary_backup=
    temporary_checksum=
    backup_path=
    checksum_path=
    backup_published=false
    checksum_published=false
    validate_runtime_paths || return 1
    acquire_deployment_lock || return 1
    load_authoritative_release || return 1
    health_failures=
    check_postgres
    [ -z "$health_failures" ] || return 1

    free_disk_kib=$(df -Pk "$backup_dir" | awk 'NR == 2 { print $4 }')
    case "$free_disk_kib" in
        "" | *[!0-9]*) return 1 ;;
    esac
    minimum_free_disk_kib=$((minimum_free_disk_gib * 1024 * 1024))
    [ "$free_disk_kib" -ge "$minimum_free_disk_kib" ] || {
        fail "Free disk is below 20 GiB."
        return 1
    }

    backup_timestamp=$(date -u +%Y%m%d-%H%M%S)
    backup_name=ladle-$backup_timestamp-$$.dump
    backup_path=$backup_dir/$backup_name
    checksum_path=$backup_path.sha256
    [ ! -e "$backup_path" ] && [ ! -e "$checksum_path" ] || return 1
    temporary_backup=$(mktemp "$backup_dir/.ladle-backup.XXXXXX") ||
        return 1
    trap cleanup_backup 0 || return 1
    trap 'exit 1' HUP INT TERM || return 1
    temporary_checksum=$(mktemp "$backup_dir/.ladle-checksum.XXXXXX") ||
        return 1

    if ! compose exec -T postgres pg_dump -Fc -U ladle ladle \
        >"$temporary_backup"; then
        return 1
    fi
    if [ ! -s "$temporary_backup" ]; then
        return 1
    fi
    if ! compose exec -T postgres pg_restore --list \
        <"$temporary_backup" >/dev/null; then
        return 1
    fi

    chmod 0600 "$temporary_backup" || return 1
    digest_output=$(sha256sum "$temporary_backup") || return 1
    backup_digest=${digest_output%% *}
    [ "${#backup_digest}" -eq 64 ] || return 1
    case "$backup_digest" in
        *[!0-9a-f]* | "") return 1 ;;
    esac
    printf '%s  %s\n' "$backup_digest" "$backup_name" \
        >"$temporary_checksum" || return 1
    chmod 0600 "$temporary_checksum" || return 1
    if ! mv -f -- "$temporary_backup" "$backup_path"; then
        [ -f "$backup_path" ] && backup_published=true
        return 1
    fi
    backup_published=true
    temporary_backup=
    if ! mv -f -- "$temporary_checksum" "$checksum_path"; then
        [ -f "$checksum_path" ] && checksum_published=true
        return 1
    fi
    checksum_published=true
    temporary_checksum=
    sync || return 1

    find "$backup_dir" -maxdepth 1 -type f \
        \( -name 'ladle-*.dump' -o -name 'ladle-*.dump.sha256' \) \
        -mtime "+$backup_retention_days" -delete ||
        return 1
    backup_size=$(stat -c '%s' -- "$backup_path") || return 1
    log_transition backup healthy \
        "validated archive $backup_name ($backup_size bytes)" ||
        return 1
    trap - 0 HUP INT TERM || return 1
    printf 'backup ready: %s\n' "$backup_name" || return 1
}

run_backup() {
    if database_backup; then
        return 0
    fi
    if cleanup_backup; then
        trap - 0 HUP INT TERM || true
    fi
    if [ "$runtime_paths_ready" = true ]; then
        log_transition backup failed "database backup did not complete" || true
    fi
    printf '%s\n' "backup failed" >&2
    return 1
}

validate_log_lines() {
    log_lines=${1:-80}
    case "$log_lines" in
        "" | *[!0-9]*) return 1 ;;
    esac
    [ "$log_lines" -ge 1 ] && [ "$log_lines" -le 500 ]
}

show_status() {
    validate_runtime_paths
    if load_authoritative_release; then
        printf '%s\n' "deployment authority: active"
        compose ps
    else
        printf '%s\n' "deployment authority: invalid"
    fi
    systemctl --no-pager --full --lines="$log_lines" status \
        ladle-health.timer ladle-backup.timer \
        ladle-health.service ladle-backup.service || true
}

show_logs() {
    journalctl --no-pager -n "$log_lines" \
        -u ladle-health.service -u ladle-backup.service
    if load_authoritative_release; then
        compose logs --no-color --tail "$log_lines" \
            caddy edge api worker beat postgres redis minio
    fi
}

operations_main() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' "Run ladle-operations as root." >&2
        return 1
    fi
    command_name=${1:-}
    case "$command_name" in
        health)
            [ "$#" -eq 1 ] || fail "Usage: ladle-operations health"
            health_check
            ;;
        backup)
            [ "$#" -eq 1 ] || fail "Usage: ladle-operations backup"
            run_backup
            ;;
        status)
            [ "$#" -le 2 ] || fail "Usage: ladle-operations status [LINES]"
            validate_log_lines "${2:-80}" ||
                fail "LINES must be between 1 and 500."
            show_status
            ;;
        logs)
            [ "$#" -le 2 ] || fail "Usage: ladle-operations logs [LINES]"
            validate_log_lines "${2:-80}" ||
                fail "LINES must be between 1 and 500."
            show_logs
            ;;
        *)
            printf '%s\n' \
                "Usage: ladle-operations {health|backup|status [LINES]|logs [LINES]}" \
                >&2
            return 64
            ;;
    esac
}

case ${0##*/} in
    operations.sh | ladle-operations) operations_main "$@" ;;
esac
