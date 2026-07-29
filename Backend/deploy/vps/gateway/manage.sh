#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

root_uid=0
root_gid=0
releases_directory=/opt/ladle/releases
live_platform=/opt/platform
live_gateway=/opt/platform/gateway
live_routes=/opt/platform/gateway/routes
gateway_env_directory=/etc/platform
gateway_env=/etc/platform/gateway.env
app_env=/etc/ladle/ladle.env
locks_directory=/var/lib/ladle/locks
authority_lock=/var/lib/ladle/locks/authority.lock
platform_network=platform-edge
gateway_project=platform-gateway
gateway_container=platform-gateway-gateway-1
legacy_container=ladle-caddy-1
gateway_image="caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
temporary_file=

usage() {
    printf '%s\n' \
        "Usage: manage.sh {prepare|activate|rollback|status}" >&2
}

fail() {
    printf '%s\n' "$*" >&2
    return 1
}

cleanup_temporary_file() {
    status=$?
    if [ -n "$temporary_file" ]; then
        rm -f -- "$temporary_file"
    fi
    trap - 0
    exit "$status"
}
trap cleanup_temporary_file 0
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -eq "$root_uid" ] ||
    fail "Run manage.sh as root."
[ "$#" -eq 1 ] || {
    usage
    exit 1
}
action=$1
case "$action" in
    prepare | activate | rollback | status) ;;
    *)
        usage
        exit 1
        ;;
esac

safe_directory() {
    safe_path=$1
    safe_mode=$2
    [ -d "$safe_path" ] && [ ! -L "$safe_path" ] || return 1
    [ "$(readlink -f -- "$safe_path")" = "$safe_path" ] || return 1
    [ "$(uid_gid_mode "$safe_path")" = \
        "$root_uid:$root_gid:$safe_mode" ]
}

uid_gid_mode() {
    metadata_path=$1
    if stat -c '%u:%g:%a' -- "$metadata_path" >/dev/null 2>&1; then
        stat -c '%u:%g:%a' -- "$metadata_path"
    else
        stat -f '%u:%g:%Lp' -- "$metadata_path"
    fi
}

safe_file() {
    safe_path=$1
    safe_mode=$2
    [ -f "$safe_path" ] && [ ! -L "$safe_path" ] || return 1
    [ "$(readlink -f -- "$safe_path")" = "$safe_path" ] || return 1
    [ "$(uid_gid_mode "$safe_path")" = \
        "$root_uid:$root_gid:$safe_mode" ]
}

ensure_directory() {
    ensure_path=$1
    ensure_mode=$2
    if [ -e "$ensure_path" ] || [ -L "$ensure_path" ]; then
        safe_directory "$ensure_path" "$ensure_mode"
        return
    fi
    install -d -o "$root_uid" -g "$root_gid" -m "$ensure_mode" \
        "$ensure_path" || return 1
    safe_directory "$ensure_path" "$ensure_mode"
}

validate_revision_value() {
    revision_value=$1
    case "$revision_value" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#revision_value}" -eq 40 ]
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
script_path=$script_directory/${0##*/}
case "$script_directory" in
    "$releases_directory"/*/Backend/deploy/vps/gateway) ;;
    *) fail "The gateway manager must run from an exact Ladle release." ;;
esac
release_relative=${script_directory#"$releases_directory"/}
revision=${release_relative%%/*}
validate_revision_value "$revision" ||
    fail "The gateway manager release revision is invalid."
release=$releases_directory/$revision
[ "$script_directory" = "$release/Backend/deploy/vps/gateway" ] ||
    fail "The gateway manager source path is not exact."

safe_directory "$releases_directory" 755 ||
    fail "The releases directory metadata is unsafe."
safe_directory "$release" 755 ||
    fail "The exact release directory metadata is unsafe."
safe_directory "$script_directory" 755 ||
    fail "The gateway source directory metadata is unsafe."
safe_directory "$script_directory/routes" 755 ||
    fail "The gateway route source directory metadata is unsafe."
safe_file "$script_path" 755 ||
    fail "The gateway manager source metadata is unsafe."
safe_file "$script_directory/docker-compose.yml" 644 ||
    fail "The gateway Compose source metadata is unsafe."
safe_file "$script_directory/Caddyfile" 644 ||
    fail "The gateway Caddy source metadata is unsafe."
safe_file "$script_directory/routes/ladle.caddy" 644 ||
    fail "The Ladle route source metadata is unsafe."
safe_file "$release/.ladle-revision" 444 ||
    fail "The release revision marker metadata is unsafe."
if ! LC_ALL=C awk -v expected="$revision" '
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
' "$release/.ladle-revision"; then
    fail "The release revision marker does not match."
fi
if find "$release" -xdev \
    \( ! -user "$root_uid" -o -perm -020 -o -perm -002 \) \
    -print -quit | grep -q .; then
    fail "The exact release is mutable or has a foreign owner."
fi

deployment_library=$release/Backend/deploy/vps/deployment-lib.sh
host_validation_library=$release/Backend/deploy/vps/host-validation.sh
safe_file "$deployment_library" 755 ||
    fail "The deployment validation library metadata is unsafe."
safe_file "$host_validation_library" 644 ||
    fail "The host validation library metadata is unsafe."
. "$deployment_library"
. "$host_validation_library"

docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ||
    fail "Docker is unavailable."

validate_app_environment() {
    app_group_id=$(
        getent group ladle-secrets |
            awk -F: 'NR == 1 { print $3 }'
    ) || return 1
    [ -n "$app_group_id" ] || return 1
    [ -f "$app_env" ] && [ ! -L "$app_env" ] || return 1
    [ "$(readlink -f -- "$app_env")" = "$app_env" ] || return 1
    [ "$(uid_gid_mode "$app_env")" = \
        "$root_uid:$app_group_id:640" ] || return 1
    validate_env_file "$app_env" || return 1
    gateway_hostname=$(dotenv_value "$app_env" LADLE_PUBLIC_HOSTNAME) ||
        return 1
    validate_hostname "$gateway_hostname" || return 1
    gateway_access_key=$(dotenv_value "$app_env" LADLE_TUNNEL_ACCESS_KEY) ||
        return 1
    validate_dotenv_value "$gateway_access_key"
}

validate_gateway_environment() {
    safe_file "$gateway_env" 600 || return 1
    validate_env_file "$gateway_env" || return 1
    gateway_environment_keys=$(
        LC_ALL=C awk -F= '{ print $1 }' "$gateway_env"
    ) || return 1
    expected_gateway_environment_keys=$(
        printf '%s\n' \
            LADLE_PUBLIC_HOSTNAME \
            LADLE_TUNNEL_ACCESS_KEY
    )
    [ "$gateway_environment_keys" = "$expected_gateway_environment_keys" ] ||
        return 1
    gateway_hostname=$(dotenv_value "$gateway_env" LADLE_PUBLIC_HOSTNAME) ||
        return 1
    validate_hostname "$gateway_hostname" || return 1
    gateway_access_key=$(
        dotenv_value "$gateway_env" LADLE_TUNNEL_ACCESS_KEY
    ) || return 1
    validate_dotenv_value "$gateway_access_key"
}

validate_gateway_environment_metadata() {
    safe_file "$gateway_env" 600
}

validate_authority_lock() {
    safe_directory "$locks_directory" 700 || return 1
    lock_file_is_safe "$authority_lock" "$root_uid"
}

ensure_authority_lock() {
    safe_directory "$locks_directory" 700 || return 1
    if [ -L "$authority_lock" ]; then
        return 1
    fi
    if [ -e "$authority_lock" ]; then
        [ -f "$authority_lock" ] || return 1
    else
        install -o "$root_uid" -g "$root_gid" -m 0600 /dev/null \
            "$authority_lock" || return 1
    fi
    validate_authority_lock
}

validate_live_assets() {
    safe_directory "$live_platform" 755 || return 1
    safe_directory "$live_gateway" 755 || return 1
    safe_directory "$live_routes" 755 || return 1
    safe_directory "$gateway_env_directory" 700 || return 1
    safe_file "$live_gateway/docker-compose.yml" 644 || return 1
    safe_file "$live_gateway/Caddyfile" 644 || return 1
    safe_file "$live_routes/ladle.caddy" 644 || return 1
    for live_route in "$live_routes"/*; do
        if [ ! -e "$live_route" ] && [ ! -L "$live_route" ]; then
            continue
        fi
        safe_file "$live_route" 644 || return 1
    done
    cmp -s "$script_directory/docker-compose.yml" \
        "$live_gateway/docker-compose.yml" || return 1
    cmp -s "$script_directory/Caddyfile" \
        "$live_gateway/Caddyfile" || return 1
    cmp -s "$script_directory/routes/ladle.caddy" \
        "$live_routes/ladle.caddy"
}

atomic_install() {
    atomic_source=$1
    atomic_target=$2
    atomic_mode=$3
    if [ -e "$atomic_target" ] || [ -L "$atomic_target" ]; then
        safe_file "$atomic_target" "$atomic_mode" || return 1
    fi
    atomic_directory=${atomic_target%/*}
    atomic_name=${atomic_target##*/}
    temporary_file=$(mktemp "$atomic_directory/.$atomic_name.XXXXXX") ||
        return 1
    install -o "$root_uid" -g "$root_gid" -m "$atomic_mode" \
        "$atomic_source" "$temporary_file" || return 1
    safe_file "$temporary_file" "$atomic_mode" || return 1
    mv -f -- "$temporary_file" "$atomic_target" || return 1
    temporary_file=
    safe_file "$atomic_target" "$atomic_mode"
}

install_gateway_environment() {
    if [ -e "$gateway_env" ] || [ -L "$gateway_env" ]; then
        safe_file "$gateway_env" 600 || return 1
    fi
    temporary_file=$(
        mktemp "$gateway_env_directory/.gateway.env.XXXXXX"
    ) || return 1
    {
        printf 'LADLE_PUBLIC_HOSTNAME=%s\n' "$gateway_hostname"
        printf 'LADLE_TUNNEL_ACCESS_KEY=%s\n' "$gateway_access_key"
    } >"$temporary_file"
    chmod 0600 "$temporary_file" || return 1
    chown "$root_uid:$root_gid" "$temporary_file" || return 1
    safe_file "$temporary_file" 600 || return 1
    validate_env_file "$temporary_file" || return 1
    mv -f -- "$temporary_file" "$gateway_env" || return 1
    temporary_file=
    validate_gateway_environment
}

gateway_compose() {
    docker compose \
        --project-name "$gateway_project" \
        --project-directory "$live_gateway" \
        --env-file "$gateway_env" \
        -f "$live_gateway/docker-compose.yml" \
        "$@"
}

validate_gateway_configuration() {
    gateway_compose config --quiet || return 1
    gateway_compose run --rm --no-deps gateway \
        caddy validate --config /etc/caddy/Caddyfile
}

prepare_gateway() {
    validate_app_environment ||
        fail "The Ladle application environment is unsafe or invalid."
    ensure_authority_lock ||
        fail "The authority lock is missing or unsafe."
    safe_directory "${live_platform%/*}" 755 ||
        fail "The /opt directory metadata is unsafe."
    safe_directory "${gateway_env_directory%/*}" 755 ||
        fail "The /etc directory metadata is unsafe."
    ensure_directory "$live_platform" 755 ||
        fail "The platform directory is unsafe."
    ensure_directory "$live_gateway" 755 ||
        fail "The gateway directory is unsafe."
    ensure_directory "$live_routes" 755 ||
        fail "The gateway routes directory is unsafe."
    ensure_directory "$gateway_env_directory" 700 ||
        fail "The gateway environment directory is unsafe."

    atomic_install "$script_directory/docker-compose.yml" \
        "$live_gateway/docker-compose.yml" 644 ||
        fail "Cannot install the gateway Compose file safely."
    atomic_install "$script_directory/Caddyfile" \
        "$live_gateway/Caddyfile" 644 ||
        fail "Cannot install the gateway Caddyfile safely."
    atomic_install "$script_directory/routes/ladle.caddy" \
        "$live_routes/ladle.caddy" 644 ||
        fail "Cannot install the Ladle gateway route safely."
    install_gateway_environment ||
        fail "Cannot install the gateway environment safely."
    validate_live_assets && validate_gateway_environment ||
        fail "The installed gateway assets are unsafe."
    ensure_platform_network || fail "$PLATFORM_NETWORK_ERROR"
    validate_gateway_configuration ||
        fail "The shared gateway configuration is invalid."
    printf '%s\n' "Gateway prepared."
}

validate_prepared_gateway() {
    validate_authority_lock || {
        fail "The authority lock is unsafe."
        return 1
    }
    validate_live_assets && validate_gateway_environment || {
        fail "The prepared gateway paths or environment are unsafe."
        return 1
    }
    platform_network_is_valid || {
        fail "$PLATFORM_NETWORK_ERROR"
        return 1
    }
}

inspect_container() {
    inspect_name=$1
    INSPECT_PRESENT=false
    INSPECT_PROJECT=
    INSPECT_SERVICE=
    INSPECT_RUNNING=
    INSPECT_HEALTH=
    inspect_record=$(
        docker inspect --format \
            '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$inspect_name" 2>/dev/null
    ) || return 0
    old_ifs=$IFS
    IFS='|'
    set -f
    set -- $inspect_record
    set +f
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    INSPECT_PRESENT=true
    INSPECT_PROJECT=$1
    INSPECT_SERVICE=$2
    INSPECT_RUNNING=$3
    INSPECT_HEALTH=$4
    case "$INSPECT_RUNNING:$INSPECT_HEALTH" in
        true:healthy | true:none | true:unhealthy | false:none | \
            true:starting | false:healthy | false:unhealthy | false:starting)
            ;;
        *) return 1 ;;
    esac
}

container_identity_is_expected() {
    expected_name=$1
    expected_project=$2
    expected_service=$3
    inspect_container "$expected_name" || return 1
    [ "$INSPECT_PRESENT" = true ] &&
        [ "$INSPECT_PROJECT" = "$expected_project" ] &&
        [ "$INSPECT_SERVICE" = "$expected_service" ]
}

container_listener_record() {
    listener_name=$1
    docker inspect --format \
        '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{range (index .HostConfig.PortBindings "80/tcp")}}{{.HostPort}}{{end}},{{range (index .HostConfig.PortBindings "443/tcp")}}{{.HostPort}}{{end}},{{range (index .HostConfig.PortBindings "443/udp")}}{{.HostPort}}{{end}}' \
        "$listener_name" 2>/dev/null
}

gateway_listener_is_ready() {
    container_identity_is_expected \
        "$gateway_container" "$gateway_project" gateway || return 1
    [ "$(container_listener_record "$gateway_container")" = \
        "true|healthy|80,443,443" ]
}

legacy_listener_is_running() {
    container_identity_is_expected "$legacy_container" ladle caddy ||
        return 1
    [ "$(container_listener_record "$legacy_container")" = \
        "true|healthy|80,443,443" ]
}

legacy_listener_is_stopped() {
    container_identity_is_expected "$legacy_container" ladle caddy ||
        return 1
    [ "$INSPECT_RUNNING" = false ]
}

gateway_listener_is_stopped() {
    container_identity_is_expected \
        "$gateway_container" "$gateway_project" gateway || return 1
    [ "$INSPECT_RUNNING" = false ]
}

wait_for_gateway_listener() {
    listener_attempt=1
    while [ "$listener_attempt" -le 30 ]; do
        if gateway_listener_is_ready; then
            return 0
        fi
        listener_attempt=$((listener_attempt + 1))
        sleep 1
    done
    return 1
}

wait_for_legacy_listener() {
    listener_attempt=1
    while [ "$listener_attempt" -le 30 ]; do
        if legacy_listener_is_running; then
            return 0
        fi
        listener_attempt=$((listener_attempt + 1))
        sleep 1
    done
    return 1
}

validate_ladle_edge() {
    platform_container_ids=$(
        docker network inspect --format \
            '{{range $id, $_ := .Containers}}{{printf "%s\n" $id}}{{end}}' \
            "$platform_network" 2>/dev/null
    ) || return 1
    ladle_edge_count=0
    set -f
    set -- $platform_container_ids
    set +f
    for edge_container_id do
        case "$edge_container_id" in
            *[!0-9a-f]*) return 1 ;;
        esac
        [ "${#edge_container_id}" -eq 64 ] || return 1
        edge_aliases=$(
            docker inspect --format \
                '{{with index .NetworkSettings.Networks "platform-edge"}}{{range .Aliases}}{{printf "%s\n" .}}{{end}}{{end}}' \
                "$edge_container_id" 2>/dev/null
        ) || return 1
        if printf '%s\n' "$edge_aliases" |
            grep -Fx ladle-edge >/dev/null; then
            container_identity_is_expected \
                "$edge_container_id" ladle edge || return 1
            [ "$INSPECT_RUNNING" = true ] || return 1
            ladle_edge_count=$((ladle_edge_count + 1))
        fi
    done
    [ "$ladle_edge_count" -eq 1 ]
}

probe_ladle_edge() {
    docker run --rm \
        --network "$platform_network" \
        --entrypoint wget \
        "$gateway_image" \
        -q -T 5 -O /dev/null \
        http://ladle-edge:8082/health/ready
}

activation_recovery_required=false

recover_failed_activation() {
    status=$?
    trap - 0 HUP INT TERM
    if [ "$activation_recovery_required" = true ]; then
        recovery_failed=false
        gateway_compose down --timeout 20 >/dev/null 2>&1 ||
            recovery_failed=true
        docker start "$legacy_container" >/dev/null 2>&1 ||
            recovery_failed=true
        wait_for_legacy_listener || recovery_failed=true
        if [ "$recovery_failed" = true ]; then
            printf '%s\n' \
                "Gateway activation failed and legacy recovery is incomplete." \
                >&2
        else
            printf '%s\n' \
                "Gateway activation failed; the legacy listener was restored." \
                >&2
        fi
    fi
    exit "$status"
}

activate_gateway() {
    validate_prepared_gateway || return 1
    validate_ladle_edge ||
        fail "The ladle-edge network identity is missing or unsafe."
    probe_ladle_edge ||
        fail "The ladle-edge readiness endpoint is unreachable."
    validate_gateway_configuration ||
        fail "The shared gateway configuration is invalid."

    inspect_container "$gateway_container" ||
        fail "The shared gateway container state is unreadable."
    if [ "$INSPECT_PRESENT" = true ]; then
        [ "$INSPECT_PROJECT:$INSPECT_SERVICE" = \
            "$gateway_project:gateway" ] ||
            fail "A foreign shared gateway container exists."
        if gateway_listener_is_ready; then
            legacy_listener_is_stopped ||
                fail "Both public listener containers are active."
            printf '%s\n' "Shared gateway is active."
            return 0
        fi
        [ "$INSPECT_RUNNING" = false ] ||
            fail "The shared gateway is running but unhealthy."
    fi
    legacy_listener_is_running ||
        fail "The exact running legacy Caddy container is unavailable."

    trap recover_failed_activation 0
    trap 'exit 1' HUP INT TERM
    activation_recovery_required=true
    docker stop --time 30 "$legacy_container" >/dev/null
    legacy_listener_is_stopped ||
        fail "The legacy listener did not stop."
    gateway_compose up -d --wait --wait-timeout 120 gateway
    gateway_listener_is_ready ||
        fail "The shared gateway did not become healthy."
    legacy_listener_is_stopped ||
        fail "The legacy listener restarted unexpectedly."
    activation_recovery_required=false
    trap - 0 HUP INT TERM
    printf '%s\n' "Shared gateway activated."
}

rollback_recovery_required=false

recover_failed_rollback() {
    status=$?
    trap - 0 HUP INT TERM
    if [ "$rollback_recovery_required" = true ]; then
        if docker start "$gateway_container" >/dev/null 2>&1 &&
            wait_for_gateway_listener; then
            printf '%s\n' \
                "Legacy rollback failed; the shared gateway was restored." \
                >&2
        else
            printf '%s\n' \
                "Legacy rollback failed and shared gateway recovery is incomplete." \
                >&2
        fi
    fi
    exit "$status"
}

rollback_gateway() {
    validate_prepared_gateway || return 1
    container_identity_is_expected \
        "$gateway_container" "$gateway_project" gateway ||
        fail "The exact shared gateway container is unavailable."
    shared_was_running=$INSPECT_RUNNING
    container_identity_is_expected "$legacy_container" ladle caddy ||
        fail "The exact legacy Caddy container is unavailable."
    if [ "$INSPECT_RUNNING" = true ]; then
        [ "$shared_was_running" = false ] ||
            fail "Both listener containers are running; refusing rollback."
        legacy_listener_is_running ||
            fail "The legacy listener state is unsafe."
        printf '%s\n' "Legacy gateway is active."
        return 0
    fi

    trap recover_failed_rollback 0
    trap 'exit 1' HUP INT TERM
    if [ "$shared_was_running" = true ]; then
        rollback_recovery_required=true
        docker stop --time 30 "$gateway_container" >/dev/null
        gateway_listener_is_stopped ||
            fail "The shared gateway did not stop."
    fi
    if ! docker start "$legacy_container" >/dev/null 2>&1 ||
        ! wait_for_legacy_listener; then
        fail "The legacy listener could not be restored."
    fi
    rollback_recovery_required=false
    trap - 0 HUP INT TERM
    printf '%s\n' "Legacy gateway restored."
}

status_gateway() {
    prepared=no
    active=no
    gateway_state=absent
    gateway_health=none
    legacy_state=absent
    legacy_health=none

    if validate_live_assets && validate_gateway_environment_metadata; then
        prepared=yes
        validate_authority_lock ||
            fail "The prepared authority lock is unsafe."
        platform_network_is_valid || fail "$PLATFORM_NETWORK_ERROR"
    elif [ -e "$live_gateway" ] || [ -L "$live_gateway" ] ||
        [ -e "$gateway_env" ] || [ -L "$gateway_env" ]; then
        fail "The gateway is only partially prepared or has unsafe metadata."
    fi

    inspect_container "$gateway_container" ||
        fail "The shared gateway state is unreadable."
    if [ "$INSPECT_PRESENT" = true ]; then
        [ "$INSPECT_PROJECT:$INSPECT_SERVICE" = \
            "$gateway_project:gateway" ] ||
            fail "A foreign shared gateway container exists."
        if [ "$INSPECT_RUNNING" = true ]; then
            gateway_state=running
            if gateway_listener_is_ready; then
                gateway_health=healthy
            else
                inspect_container "$gateway_container" || return 1
                gateway_health=$INSPECT_HEALTH
            fi
        else
            gateway_state=stopped
        fi
    fi

    inspect_container "$legacy_container" ||
        fail "The legacy gateway state is unreadable."
    if [ "$INSPECT_PRESENT" = true ]; then
        [ "$INSPECT_PROJECT:$INSPECT_SERVICE" = "ladle:caddy" ] ||
            fail "A foreign legacy Caddy container exists."
        if [ "$INSPECT_RUNNING" = true ]; then
            legacy_listener_is_running ||
                fail "The running legacy listener bindings are unsafe."
            legacy_state=running
            legacy_health=healthy
        else
            legacy_state=stopped
        fi
    fi

    if [ "$prepared:$gateway_state:$gateway_health:$legacy_state" = \
        "yes:running:healthy:stopped" ]; then
        active=yes
    elif [ "$gateway_state:$legacy_state" = "absent:running" ] ||
        [ "$gateway_state:$legacy_state" = "stopped:running" ]; then
        active=no
    else
        printf 'prepared=%s\nactive=%s\ngateway=%s\n' \
            "$prepared" "$active" "$gateway_state"
        printf 'gateway_health=%s\nlegacy=%s\nlegacy_health=%s\n' \
            "$gateway_health" "$legacy_state" "$legacy_health"
        fail "The gateway listener state is inconsistent."
    fi

    printf 'prepared=%s\nactive=%s\ngateway=%s\n' \
        "$prepared" "$active" "$gateway_state"
    printf 'gateway_health=%s\nlegacy=%s\nlegacy_health=%s\n' \
        "$gateway_health" "$legacy_state" "$legacy_health"
}

case "$action" in
    prepare) prepare_gateway ;;
    activate) activate_gateway ;;
    rollback) rollback_gateway ;;
    status) status_gateway ;;
esac
