#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

env_file=/etc/ladle/ladle.env
current_release=/opt/ladle/current
releases_directory=/opt/ladle/releases
deployment_state=/var/lib/ladle/deployment-state
operations_state=/var/lib/ladle/operations
backup_dir=/var/backups/ladle
operations_log=/var/log/ladle/operations.log
deployment_lock=/var/lib/ladle/locks/deploy.lock
transition_lock=/var/lib/ladle/locks/transition.lock
backup_retention_days=35
minimum_free_disk_gib=20
backup_max_age_hours=36
certificate_minimum_seconds=604800
beat_stability_observations=3
beat_stability_interval_seconds=1
temporary_backup=
temporary_checksum=
backup_path=
checksum_path=
backend_directory=
base_compose=
vps_compose=
runtime_paths_ready=false
authoritative_release_loaded=false

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

validate_expected_release() {
    expected_release=${LADLE_OPERATIONS_EXPECTED_RELEASE:-}
    expected_revision=${expected_release##*/}
    validate_revision "$expected_revision" || return 1
    [ "$expected_release" = "$releases_directory/$expected_revision" ]
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
    safe_regular_file "$transition_lock" 600 || {
        fail "Transition lock metadata is unsafe."
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
    authoritative_release_loaded=false
    validate_expected_release || {
        fail "Operations release handoff is invalid."
        return 1
    }
    safe_regular_file "$deployment_state" 644 || {
        fail "Deployment state metadata is unsafe."
        return 1
    }
    state_sentinel=__LADLE_STATE_SNAPSHOT_END__
    state_snapshot=$(
        cat "$deployment_state" &&
            printf '%s' "$state_sentinel"
    ) || {
        fail "Cannot read deployment state."
        return 1
    }
    case "$state_snapshot" in
        *"$state_sentinel") ;;
        *)
            fail "Cannot read deployment state."
            return 1
            ;;
    esac
    state_contents=${state_snapshot%"$state_sentinel"}
    [ "$(printf '%s' "$state_contents" | wc -l | tr -d ' ')" = 3 ] || {
        fail "Deployment state has an invalid shape."
        return 1
    }

    status_line=$(printf '%s' "$state_contents" | sed -n '1p')
    revision_line=$(printf '%s' "$state_contents" | sed -n '2p')
    phase_line=$(printf '%s' "$state_contents" | sed -n '3p')
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
    [ "$revision" = "$expected_revision" ] || {
        fail "Deployment state does not match the operations handoff."
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
    [ "$resolved_release" = "$expected_release" ] || {
        fail "Current release does not match the operations handoff."
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
    authoritative_release_loaded=true
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

acquire_transition_lock() {
    safe_regular_file "$transition_lock" 600 || return 1
    exec 8>"$transition_lock"
    flock 8 || return 1
    safe_regular_file "$transition_lock" 600
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
    acquire_transition_lock || return 1
    previous_transition=$(read_transition_state "$transition_file") || return 1
    [ "$previous_transition" = "$transition_state" ] && return 0
    transition_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
    if ! printf '%s %s %s: %s\n' \
        "$transition_timestamp" \
        "$transition_kind" "$transition_state" "$transition_message" \
        >>"$operations_log"; then
        return 1
    fi
    write_transition_state "$transition_file" "$transition_state" || return 1
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
    container_health_requirement=${2:-optional}
    container_id=$(compose ps -q "$container_service" 2>/dev/null) || return 1
    [ -n "$container_id" ] || return 1
    container_state=$(
        docker inspect \
            --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$container_id" 2>/dev/null
    ) || return 1
    case "$container_state" in
        true\|healthy) return 0 ;;
        true\|none)
            [ "$container_health_requirement" = optional ]
            ;;
        *) return 1 ;;
    esac
}

beat_is_stable() {
    beat_expected_id=$(compose ps --status running -q beat) || return 1
    case "$beat_expected_id" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#beat_expected_id}" -eq 64 ] || return 1
    beat_observation=1
    while [ "$beat_observation" -le "$beat_stability_observations" ]; do
        beat_current_id=$(compose ps --status running -q beat) || return 1
        [ "$beat_current_id" = "$beat_expected_id" ] || return 1
        beat_state=$(
            docker inspect \
                --format '{{.State.Running}} {{.State.Restarting}} {{.RestartCount}}' \
                "$beat_expected_id" 2>/dev/null
        ) || return 1
        set -f
        set -- $beat_state
        set +f
        [ "$#" -eq 3 ] || return 1
        [ "$1" = true ] && [ "$2" = false ] && [ "$3" = 0 ] || return 1
        if [ "$beat_observation" -lt "$beat_stability_observations" ]; then
            sleep "$beat_stability_interval_seconds" || return 1
        fi
        beat_observation=$((beat_observation + 1))
    done
}

check_containers() {
    for runtime_service in \
        edge api worker beat postgres redis minio; do
        if ! container_is_ready "$runtime_service"; then
            append_failure "$runtime_service container"
        fi
    done
    if ! container_is_ready worker-egress healthy; then
        append_failure "worker-egress container"
    fi
    if ! beat_is_stable; then
        append_failure "beat stability"
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

backup_pair_is_valid() {
    pair_backup=$1
    pair_checksum=$2
    safe_regular_file "$pair_backup" 600 || return 1
    safe_regular_file "$pair_checksum" 600 || return 1
    pair_basename=$(basename -- "$pair_backup") || return 1
    checksum_line=$(cat "$pair_checksum") || return 1
    checksum_digest=${checksum_line%%  *}
    [ "$checksum_line" = "$checksum_digest  $pair_basename" ] || return 1
    [ "${#checksum_digest}" -eq 64 ] || return 1
    case "$checksum_digest" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    (
        cd "$backup_dir" || exit 1
        sha256sum -c --status "$(basename -- "$pair_checksum")"
    )
}

latest_backup_path() {
    find "$backup_dir" -maxdepth 1 -type f -name 'ladle-*.dump' \
        -printf '%T@ %p\n' |
        LC_ALL=C sort -rn |
        while read -r candidate_mtime candidate_backup; do
        [ -n "$candidate_mtime" ] && [ -n "$candidate_backup" ] || continue
        candidate_checksum=$candidate_backup.sha256
        backup_pair_is_valid "$candidate_backup" "$candidate_checksum" ||
            continue
        printf '%s\n' "$candidate_backup"
        break
    done
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
    backup_now=$(date +%s) || {
        append_failure "backup is stale"
        return
    }
    backup_mtime=$(stat -c '%Y' -- "$latest_backup") || {
        append_failure "backup is stale"
        return
    }
    backup_age_seconds=$((backup_now - backup_mtime))
    if [ "$backup_age_seconds" -lt 0 ] ||
        [ "$backup_age_seconds" -gt $((backup_max_age_hours * 3600)) ]; then
        append_failure "backup is stale"
        return
    fi
}

health_check() {
    health_failures=
    authoritative_release_loaded=false
    if ! validate_runtime_paths || ! load_authoritative_release; then
        printf '%s\n' "health failed: deployment authority" >&2
        return 1
    fi
    check_containers
    check_nginx
    check_api
    check_worker
    check_postgres
    check_redis
    check_minio
    check_certificate
    check_backup_freshness

    if [ -n "$health_failures" ]; then
        log_transition health failed "$health_failures" || true
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
    backup_final_exists=false
    checksum_final_exists=false
    if [ -n "$backup_path" ] &&
        { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        backup_final_exists=true
    fi
    if [ -n "$checksum_path" ] &&
        { [ -e "$checksum_path" ] || [ -L "$checksum_path" ]; }; then
        checksum_final_exists=true
    fi
    if [ "$backup_final_exists" != "$checksum_final_exists" ]; then
        if [ "$backup_final_exists" = true ]; then
            incomplete_final=$backup_path
        else
            incomplete_final=$checksum_path
        fi
        if ! safe_regular_file "$incomplete_final" 600 ||
            ! rm -f -- "$incomplete_final"; then
            cleanup_status=1
        fi
    fi
    [ "$cleanup_status" -eq 0 ]
}

remove_incomplete_backup_pairs() {
    for incomplete_dump in "$backup_dir"/ladle-*.dump; do
        if [ ! -e "$incomplete_dump" ] && [ ! -L "$incomplete_dump" ]; then
            continue
        fi
        incomplete_checksum=$incomplete_dump.sha256
        if [ -e "$incomplete_checksum" ] || [ -L "$incomplete_checksum" ]; then
            continue
        fi
        safe_regular_file "$incomplete_dump" 600 || return 1
        rm -f -- "$incomplete_dump" || return 1
    done
    for incomplete_checksum in "$backup_dir"/ladle-*.dump.sha256; do
        if [ ! -e "$incomplete_checksum" ] &&
            [ ! -L "$incomplete_checksum" ]; then
            continue
        fi
        incomplete_dump=${incomplete_checksum%.sha256}
        if [ -e "$incomplete_dump" ] || [ -L "$incomplete_dump" ]; then
            continue
        fi
        safe_regular_file "$incomplete_checksum" 600 || return 1
        rm -f -- "$incomplete_checksum" || return 1
    done
}

retain_backup_pairs() {
    for retained_dump in "$backup_dir"/ladle-*.dump; do
        if [ ! -e "$retained_dump" ] && [ ! -L "$retained_dump" ]; then
            continue
        fi
        retained_checksum=$retained_dump.sha256
        if [ ! -e "$retained_checksum" ] &&
            [ ! -L "$retained_checksum" ]; then
            continue
        fi
        safe_regular_file "$retained_dump" 600 || return 1
        safe_regular_file "$retained_checksum" 600 || return 1
        expired_backup=$(
            find "$retained_dump" -prune \
                -mtime "+$backup_retention_days" -print
        ) || return 1
        [ -n "$expired_backup" ] || continue
        rm -f -- "$retained_dump" "$retained_checksum" || return 1
    done
}

database_backup() {
    temporary_backup=
    temporary_checksum=
    backup_path=
    checksum_path=
    authoritative_release_loaded=false
    validate_runtime_paths || return 1
    load_authoritative_release || return 1
    acquire_deployment_lock || return 1
    remove_incomplete_backup_pairs || return 1
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

    backup_timestamp=$(date -u +%Y%m%d-%H%M%S) || return 1
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
    mv -f -- "$temporary_backup" "$backup_path" || return 1
    temporary_backup=
    mv -f -- "$temporary_checksum" "$checksum_path" || return 1
    temporary_checksum=
    sync || return 1

    retain_backup_pairs || return 1
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
    if [ "$authoritative_release_loaded" != true ]; then
        printf '%s\n' "backup failed" >&2
        return 1
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
    if ! validate_runtime_paths || ! load_authoritative_release; then
        printf '%s\n' "deployment authority: invalid"
        return 1
    fi
    printf '%s\n' "deployment authority: active"
    compose ps || return 1
    if systemctl --no-pager --full --lines="$log_lines" status \
        ladle-health.timer ladle-backup.timer \
        ladle-health.service ladle-backup.service; then
        return 0
    else
        systemctl_status=$?
    fi
    [ "$systemctl_status" -eq 3 ] && return 0
    return "$systemctl_status"
}

show_logs() {
    load_authoritative_release || return 1
    journalctl --no-pager -n "$log_lines" \
        -u ladle-health.service -u ladle-backup.service || return 1
    compose logs --no-color --tail "$log_lines" \
        edge api worker worker-egress beat postgres redis minio || return 1
}

operations_main() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' "Run ladle-operations as root." >&2
        return 1
    fi
    validate_expected_release || {
        fail "Operations release handoff is invalid."
        return 1
    }
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
