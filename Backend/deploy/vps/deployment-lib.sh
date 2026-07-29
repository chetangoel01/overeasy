#!/bin/sh
set -eu
umask 077

progress_log=/var/log/ladle/setup.log

die() {
    printf '%s\n' "$*" >&2
    return 1
}

validate_revision() {
    revision_candidate=$1
    case "$revision_candidate" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#revision_candidate}" -eq 40 ]
}

validate_hostname() {
    hostname_candidate=$1
    case "$hostname_candidate" in
        "" | *[!A-Za-z0-9.-]* | .* | *..* | *.)
            return 1
            ;;
    esac
    [ "${#hostname_candidate}" -le 253 ]
}

validate_dotenv_value() {
    dotenv_candidate=$1
    case "$dotenv_candidate" in
        "" | *[!A-Za-z0-9._:/@+-]*) return 1 ;;
        *) [ "${#dotenv_candidate}" -le 4096 ] ;;
    esac
}

read_dotenv_stdin_value() {
    DOTENV_STDIN_VALUE=
    if ! IFS= read -r DOTENV_STDIN_VALUE; then
        [ -n "$DOTENV_STDIN_VALUE" ] || return 1
    fi
    dotenv_extra_line=
    if IFS= read -r dotenv_extra_line || [ -n "$dotenv_extra_line" ]; then
        return 1
    fi
    validate_dotenv_value "$DOTENV_STDIN_VALUE"
}

validate_env_file() {
    dotenv_file=$1
    [ -f "$dotenv_file" ] && [ ! -L "$dotenv_file" ] || return 1
    LC_ALL=C awk '
        $0 !~ /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:\/@+-]+$/ {
            invalid = 1
            next
        }
        {
            key = $0
            sub(/=.*/, "", key)
            if (seen[key]++) {
                invalid = 1
            }
        }
        END {
            exit invalid
        }
    ' "$dotenv_file"
}

dotenv_value() {
    dotenv_file=$1
    dotenv_key=$2
    case "$dotenv_key" in
        "" | *[!A-Z0-9_]* | [0-9_]*) return 1 ;;
    esac
    validate_env_file "$dotenv_file" || return 1
    LC_ALL=C awk -F= -v target="$dotenv_key" '
        $1 == target {
            found++
            print substr($0, length($1) + 2)
        }
        END {
            exit found != 1
        }
    ' "$dotenv_file"
}

validate_required_env() {
    required_env_file=$1
    shift
    validate_env_file "$required_env_file" || return 1
    for required_env_key do
        dotenv_value "$required_env_file" "$required_env_key" >/dev/null ||
            return 1
    done
}

validate_env_metadata() {
    metadata_file=$1
    metadata_group=$2
    [ -f "$metadata_file" ] && [ ! -L "$metadata_file" ] || return 1
    expected_group_id=$(getent group "$metadata_group" | awk -F: 'NR == 1 { print $3 }')
    [ -n "$expected_group_id" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$metadata_file")" = "0:$expected_group_id:640" ]
}

file_uid_mode() {
    metadata_target=$1
    if stat -c '%u:%a' -- "$metadata_target" >/dev/null 2>&1; then
        stat -c '%u:%a' -- "$metadata_target"
    else
        stat -f '%u:%Lp' -- "$metadata_target"
    fi
}

release_directory_is_safe() {
    safe_release=$1
    safe_release_uid=$2
    [ -d "$safe_release" ] && [ ! -L "$safe_release" ] || return 1
    [ "$(readlink -f -- "$safe_release")" = "$safe_release" ] || return 1
    [ "$(file_uid_mode "$safe_release")" = "$safe_release_uid:755" ] || return 1
    for safe_release_script in \
        Backend/deploy/vps/initialize-env.sh \
        Backend/deploy/vps/deploy.sh \
        Backend/deploy/vps/deployment-lib.sh; do
        [ -f "$safe_release/$safe_release_script" ] &&
            [ ! -L "$safe_release/$safe_release_script" ] || return 1
        [ "$(file_uid_mode "$safe_release/$safe_release_script")" = \
            "$safe_release_uid:755" ] || return 1
    done
    for safe_release_config in \
        Backend/docker-compose.yml \
        Backend/deploy/vps/docker-compose.yml; do
        [ -f "$safe_release/$safe_release_config" ] &&
            [ ! -L "$safe_release/$safe_release_config" ] || return 1
        [ "$(file_uid_mode "$safe_release/$safe_release_config")" = \
            "$safe_release_uid:644" ] || return 1
    done
}

lock_file_is_safe() {
    safe_lock=$1
    safe_lock_uid=$2
    [ -f "$safe_lock" ] && [ ! -L "$safe_lock" ] || return 1
    [ "$(readlink -f -- "$safe_lock")" = "$safe_lock" ] || return 1
    [ "$(file_uid_mode "$safe_lock")" = "$safe_lock_uid:600" ]
}

acquire_environment_lock() {
    environment_lock_path=$1
    environment_lock_uid=$2
    lock_file_is_safe "$environment_lock_path" "$environment_lock_uid" ||
        return 1
    exec 8>"$environment_lock_path"
    flock 8 || return 1
    lock_file_is_safe "$environment_lock_path" "$environment_lock_uid"
}

acquire_deployment_lock() {
    deployment_lock_path=$1
    deployment_lock_uid=$2
    lock_file_is_safe "$deployment_lock_path" "$deployment_lock_uid" ||
        return 1
    exec 9>"$deployment_lock_path"
    flock -n 9 || return 1
    lock_file_is_safe "$deployment_lock_path" "$deployment_lock_uid"
}

acquire_authority_lock() {
    authority_lock_path=$1
    authority_lock_uid=$2
    lock_file_is_safe "$authority_lock_path" "$authority_lock_uid" ||
        return 1
    exec 7>"$authority_lock_path"
    flock 7 || return 1
    lock_file_is_safe "$authority_lock_path" "$authority_lock_uid"
}

validate_staging_environment() {
    staging_env_file=$1
    validate_required_env "$staging_env_file" \
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
        return 1
    staging_hostname=$(dotenv_value "$staging_env_file" LADLE_PUBLIC_HOSTNAME) ||
        return 1
    validate_hostname "$staging_hostname" || return 1
    staging_database_password=$(
        dotenv_value "$staging_env_file" LADLE_DATABASE_PASSWORD
    ) || return 1
    staging_encoded_password=$(
        dotenv_value "$staging_env_file" LADLE_DATABASE_PASSWORD_URL_ENCODED
    ) || return 1
    [ "$staging_database_password" = "$staging_encoded_password" ] || return 1
    staging_provider_mode=$(
        dotenv_value "$staging_env_file" LADLE_WORKER_PROVIDER_MODE
    ) || return 1
    case "$staging_provider_mode" in
        fake) ;;
        live)
            dotenv_value "$staging_env_file" LADLE_OPENROUTER_API_KEY \
                >/dev/null || return 1
            ;;
        *) return 1 ;;
    esac
}

write_provider_secret_candidate() {
    provider_source=$1
    provider_candidate=$2
    provider_name=$3
    provider_value=$4
    validate_staging_environment "$provider_source" || return 1
    validate_dotenv_value "$provider_value" || return 1
    case "$provider_name" in
        LADLE_OPENROUTER_API_KEY | \
            LADLE_SUPADATA_API_KEY | \
            LADLE_SOSCRIPTED_API_KEY)
            ;;
        *) return 1 ;;
    esac
    [ ! -e "$provider_candidate" ] || [ -f "$provider_candidate" ] || return 1
    if [ "$provider_name" = LADLE_OPENROUTER_API_KEY ]; then
        grep -v -E \
            '^(LADLE_OPENROUTER_API_KEY|LADLE_WORKER_PROVIDER_MODE)=' \
            "$provider_source" >"$provider_candidate" || true
        printf '%s=%s\n' "$provider_name" "$provider_value" >>"$provider_candidate"
        printf 'LADLE_WORKER_PROVIDER_MODE=live\n' >>"$provider_candidate"
    else
        grep -v -E "^${provider_name}=" \
            "$provider_source" >"$provider_candidate" || true
        printf '%s=%s\n' "$provider_name" "$provider_value" >>"$provider_candidate"
    fi
    validate_staging_environment "$provider_candidate"
}

write_deployment_state() {
    state_directory=$1
    state_status=$2
    state_revision=$3
    state_phase=$4
    state_uid=$5
    [ -d "$state_directory" ] && [ ! -L "$state_directory" ] || return 1
    [ "$(readlink -f -- "$state_directory")" = "$state_directory" ] || return 1
    [ "$(file_uid_mode "$state_directory")" = "$state_uid:750" ] || return 1
    case "$state_status" in
        deploying | failed | active) ;;
        *) return 1 ;;
    esac
    validate_revision "$state_revision" || return 1
    case "$state_phase" in
        "" | *[!a-z0-9-]*) return 1 ;;
    esac
    deployment_state_tmp=$(mktemp "$state_directory/.deployment-state.XXXXXX") ||
        return 1
    if ! {
        {
            printf 'STATUS=%s\n' "$state_status"
            printf 'REVISION=%s\n' "$state_revision"
            printf 'PHASE=%s\n' "$state_phase"
        } >"$deployment_state_tmp" &&
            chmod 0644 "$deployment_state_tmp" &&
            [ "$(file_uid_mode "$deployment_state_tmp")" = "$state_uid:644" ] &&
            mv -f -- "$deployment_state_tmp" "$state_directory/deployment-state" &&
            sync
    }; then
        rm -f -- "$deployment_state_tmp"
        return 1
    fi
    deployment_state_tmp=
}

deployment_state_matches_current() {
    active_state_file=$1
    active_current=$2
    active_state_uid=${3:-0}
    [ -f "$active_state_file" ] && [ ! -L "$active_state_file" ] || return 1
    [ "$(file_uid_mode "$active_state_file")" = "$active_state_uid:644" ] ||
        return 1
    [ -L "$active_current" ] || return 1
    active_release=$(readlink -f -- "$active_current") || return 1
    active_revision=${active_release##*/}
    validate_revision "$active_revision" || return 1
    LC_ALL=C awk -F= -v revision="$active_revision" '
        $0 !~ /^(STATUS|REVISION|PHASE)=[a-z0-9-]+$/ {
            invalid = 1
        }
        $1 == "STATUS" {
            status_count++
            status = $2
        }
        $1 == "REVISION" {
            revision_count++
            state_revision = $2
        }
        $1 == "PHASE" {
            phase_count++
            phase = $2
        }
        END {
            if (invalid ||
                NR != 3 ||
                status_count != 1 ||
                revision_count != 1 ||
                phase_count != 1 ||
                status != "active" ||
                state_revision != revision ||
                phase != "complete") {
                exit 1
            }
        }
    ' "$active_state_file"
}

rollout_worker_pair() {
    compose rm -f -s worker || return 1
    compose up -d --no-build --no-deps --wait --wait-timeout 120 \
        worker-egress || return 1
    compose up -d --no-build --no-deps --wait --wait-timeout 120 \
        --force-recreate worker
}

wait_for_beat_stability() {
    beat_checks=$1
    beat_interval=$2
    case "$beat_checks:$beat_interval" in
        *[!0-9:]*) return 1 ;;
    esac
    [ "$beat_checks" -ge 3 ] && [ "$beat_checks" -le 20 ] || return 1
    [ "$beat_interval" -ge 1 ] && [ "$beat_interval" -le 30 ] || return 1
    beat_expected_id=$(compose ps --status running -q beat) || return 1
    case "$beat_expected_id" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#beat_expected_id}" -eq 64 ] || return 1
    beat_observation=1
    while [ "$beat_observation" -le "$beat_checks" ]; do
        beat_current_id=$(compose ps --status running -q beat) || return 1
        [ "$beat_current_id" = "$beat_expected_id" ] || return 1
        beat_state=$(
            docker inspect \
                --format '{{.State.Running}} {{.State.Restarting}} {{.RestartCount}}' \
                "$beat_expected_id"
        ) || return 1
        set -f
        set -- $beat_state
        set +f
        [ "$#" -eq 3 ] || return 1
        [ "$1" = true ] && [ "$2" = false ] && [ "$3" = 0 ] || return 1
        if [ "$beat_observation" -lt "$beat_checks" ]; then
            sleep "$beat_interval"
        fi
        beat_observation=$((beat_observation + 1))
    done
}

revision_marker_matches() {
    marker_file=$1
    expected_revision=$2
    [ -f "$marker_file" ] && [ ! -L "$marker_file" ] || return 1
    LC_ALL=C awk -v expected="$expected_revision" '
        NR == 1 && $0 == expected {
            matched = 1
            next
        }
        {
            matched = 0
        }
        END {
            exit !(matched && NR == 1)
        }
    ' "$marker_file"
}

activate_release() {
    activation_release=$1
    activation_current=$2
    [ -d "$activation_release" ] && [ ! -L "$activation_release" ] || return 1
    activation_canonical=$(readlink -f -- "$activation_release") || return 1
    [ "$activation_canonical" = "$activation_release" ] || return 1
    if [ -e "$activation_current" ] && [ ! -L "$activation_current" ]; then
        return 1
    fi
    activation_link=$activation_current.next.$$
    [ ! -e "$activation_link" ] && [ ! -L "$activation_link" ] || return 1
    ln -s -- "$activation_release" "$activation_link" || return 1
    activation_status=0
    if mv --help 2>/dev/null | grep -q -- '--no-target-directory'; then
        mv -Tf -- "$activation_link" "$activation_current" ||
            activation_status=$?
    else
        mv -fh -- "$activation_link" "$activation_current" ||
            activation_status=$?
    fi
    if [ "$activation_status" -ne 0 ]; then
        rm -f -- "$activation_link"
        return 1
    fi
}

activate_deployment_revision() {
    activation_state_directory=$1
    activation_revision=$2
    activation_release=$3
    activation_current=$4
    activation_state_uid=$5
    write_deployment_state "$activation_state_directory" active \
        "$activation_revision" complete "$activation_state_uid" ||
        return 1
    activate_release "$activation_release" "$activation_current"
}

finalize_deployment_exit() {
    finalization_status=$1
    finalization_state_started=$2
    finalization_state_directory=$3
    finalization_revision=$4
    finalization_phase=$5
    finalization_current=$6
    finalization_state_uid=$7
    DEPLOYMENT_FINAL_STATUS=$finalization_status
    DEPLOYMENT_COMMIT_RECOVERED=false
    case "$finalization_status" in
        "" | *[!0-9]*) return 1 ;;
    esac
    case "$finalization_state_started" in
        true | false) ;;
        *) return 1 ;;
    esac
    [ "$finalization_status" -ne 0 ] || return 0
    if [ "$finalization_state_started" = true ] &&
        deployment_state_matches_current \
            "$finalization_state_directory/deployment-state" \
            "$finalization_current" "$finalization_state_uid"; then
        DEPLOYMENT_FINAL_STATUS=0
        DEPLOYMENT_COMMIT_RECOVERED=true
        return 0
    fi
    if [ "$finalization_state_started" = true ]; then
        write_deployment_state "$finalization_state_directory" failed \
            "$finalization_revision" "$finalization_phase" \
            "$finalization_state_uid" ||
            true
    fi
    return 0
}

validate_progress_text() {
    progress_phase_candidate=$1
    progress_message_candidate=$2
    case "$progress_phase_candidate" in
        "" | *[!a-z0-9-]*) return 1 ;;
    esac
    LC_ALL=C printf '%s\n' "$progress_message_candidate" |
        LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9.,_:/() -]*$'
}

progress_init() {
    progress_group=$1
    [ "$(id -u)" -eq 0 ] || return 1
    if ! getent group "$progress_group" >/dev/null 2>&1; then
        groupadd --system "$progress_group"
    fi
    progress_group_id=$(
        getent group "$progress_group" | awk -F: 'NR == 1 { print $3 }'
    )
    [ -n "$progress_group_id" ] || return 1
    if [ -e /var/log/ladle ] || [ -L /var/log/ladle ]; then
        [ -d /var/log/ladle ] && [ ! -L /var/log/ladle ] || return 1
    else
        install -d -o root -g "$progress_group" -m 0750 /var/log/ladle
    fi
    [ "$(readlink -f -- /var/log/ladle)" = /var/log/ladle ] || return 1
    chown root:"$progress_group" /var/log/ladle
    chmod 0750 /var/log/ladle
    if [ -e "$progress_log" ] || [ -L "$progress_log" ]; then
        [ -f "$progress_log" ] && [ ! -L "$progress_log" ] || return 1
    else
        install -o root -g "$progress_group" -m 0640 /dev/null "$progress_log"
    fi
    chown root:"$progress_group" "$progress_log"
    chmod 0640 "$progress_log"
    [ "$(stat -c '%u:%g:%a' -- "$progress_log")" = "0:$progress_group_id:640" ]
}

progress() {
    progress_phase=$1
    progress_message=$2
    validate_progress_text "$progress_phase" "$progress_message" || return 1
    progress_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    progress_line="[$progress_timestamp] $progress_phase: $progress_message"
    printf "%s\n" "$progress_line"
    printf "%s\n" "$progress_line" >>"$progress_log"
}
