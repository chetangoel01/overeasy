#!/bin/sh

# Pure validation helpers shared by the root-only host scripts and unprivileged
# contract tests. These functions must not mutate host configuration.

docker_key_metadata_is_trusted() {
    docker_metadata_file=$1
    docker_expected_fingerprint=$2

    awk -F: -v expected="$docker_expected_fingerprint" '
        BEGIN {
            valid = 1
            awaiting_primary_fingerprint = 0
        }
        $1 == "pub" {
            if (awaiting_primary_fingerprint) {
                valid = 0
            }
            primary_count++
            awaiting_primary_fingerprint = 1
            next
        }
        $1 == "sub" {
            if (awaiting_primary_fingerprint) {
                valid = 0
            }
            awaiting_primary_fingerprint = 0
            next
        }
        $1 == "fpr" && awaiting_primary_fingerprint {
            primary_fingerprint_count++
            if ($10 != expected) {
                valid = 0
            }
            awaiting_primary_fingerprint = 0
        }
        END {
            if (awaiting_primary_fingerprint) {
                valid = 0
            }
            exit !(valid && primary_count == 1 && primary_fingerprint_count == 1)
        }
    ' "$docker_metadata_file"
}

public_interface_from_routes() {
    awk '
        $1 == "default" {
            route_interface = ""
            for (field = 1; field <= NF; field++) {
                if ($field == "dev" && field < NF) {
                    route_interface = $(field + 1)
                    break
                }
            }
            if (route_interface == "") {
                invalid = 1
            } else if (public_interface != "" && public_interface != route_interface) {
                invalid = 1
            } else {
                public_interface = route_interface
            }
        }
        END {
            if (invalid || public_interface == "") {
                exit 1
            }
            print public_interface
        }
    '
}

public_interface_is_safe() {
    candidate_interface=$1
    case "$candidate_interface" in
        "" | [-.:_]* | *[!A-Za-z0-9_.:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

render_docker_firewall() {
    firewall_template=$1
    rendered_ipv4_interface=$2
    rendered_ipv6_interface=$3

    public_interface_is_safe "$rendered_ipv4_interface" || return 1
    public_interface_is_safe "$rendered_ipv6_interface" || return 1
    grep -q '@PUBLIC_IPV4_INTERFACE@' "$firewall_template" || return 1
    grep -q '@PUBLIC_IPV6_INTERFACE@' "$firewall_template" || return 1
    /usr/bin/sed \
        -e "s/@PUBLIC_IPV4_INTERFACE@/$rendered_ipv4_interface/g" \
        -e "s/@PUBLIC_IPV6_INTERFACE@/$rendered_ipv6_interface/g" \
        "$firewall_template"
}

PLATFORM_NETWORK_ERROR=
PLATFORM_NETWORK_STATUS=

platform_network_fail() {
    PLATFORM_NETWORK_STATUS=$1
    PLATFORM_NETWORK_ERROR=$2
    return 1
}

platform_network_is_valid() {
    PLATFORM_NETWORK_ERROR=
    PLATFORM_NETWORK_STATUS=
    platform_contract=$(
        docker network inspect --format \
            '{{printf "%s\n%s\n%t\n%d\n" .Driver .Scope .Internal (len .IPAM.Config)}}{{range .IPAM.Config}}{{printf "%s\n" .Subnet}}{{end}}{{index .Labels "com.ladle.platform.network"}}' \
            platform-edge 2>/dev/null
    ) || {
        platform_network_fail missing \
            "The shared platform-edge Docker network is missing or unreadable."
        return 1
    }
    expected_platform_contract=$(
        printf '%s\n' \
            bridge local false 1 172.30.0.0/24 shared-edge-v1
    )
    if [ "$platform_contract" != "$expected_platform_contract" ]; then
        platform_network_fail invalid \
            "The shared platform-edge Docker network violates the required local bridge contract."
        return 1
    fi

    platform_container_ids=$(
        docker network inspect --format \
            '{{range $id, $_ := .Containers}}{{printf "%s\n" $id}}{{end}}' \
            platform-edge 2>/dev/null
    ) || {
        platform_network_fail invalid \
            "The shared platform-edge Docker network endpoints are unreadable."
        return 1
    }
    set -f
    set -- $platform_container_ids
    set +f
    for platform_container_id do
        case "$platform_container_id" in
            *[!0-9a-f]*) platform_container_id=invalid ;;
        esac
        if [ "${#platform_container_id}" -ne 64 ]; then
            platform_network_fail invalid \
                "The shared platform-edge Docker network has an unsafe endpoint identity."
            return 1
        fi
        platform_aliases=$(
            docker inspect --format \
                '{{with index .NetworkSettings.Networks "platform-edge"}}{{range .Aliases}}{{printf "%s\n" .}}{{end}}{{end}}' \
                "$platform_container_id" 2>/dev/null
        ) || {
            platform_network_fail invalid \
                "A shared platform-edge Docker network endpoint is unreadable."
            return 1
        }
        if printf '%s\n' "$platform_aliases" |
            grep -Fx ladle-edge >/dev/null; then
            platform_alias_owner=$(
                docker inspect --format \
                    '{{index .Config.Labels "com.docker.compose.project"}}{{printf "\n"}}{{index .Config.Labels "com.docker.compose.service"}}' \
                    "$platform_container_id" 2>/dev/null
            ) || {
                platform_network_fail invalid \
                    "The ladle-edge alias owner labels are unreadable."
                return 1
            }
            expected_platform_alias_owner=$(printf '%s\n' ladle edge)
            if [ "$platform_alias_owner" != "$expected_platform_alias_owner" ]; then
                platform_network_fail invalid \
                    "The ladle-edge alias is advertised by a foreign container."
                return 1
            fi
        fi
    done
}

ensure_platform_network() {
    if platform_network_is_valid; then
        return 0
    fi
    [ "$PLATFORM_NETWORK_STATUS" = missing ] || return 1
    if docker network create \
        --driver bridge \
        --subnet 172.30.0.0/24 \
        --label com.ladle.platform.network=shared-edge-v1 \
        platform-edge >/dev/null; then
        platform_network_is_valid
        return
    fi
    # A concurrent provisioner may have created the exact network first.
    platform_network_is_valid
}

authorized_keys_has_valid_key() {
    /usr/bin/ssh-keygen -l -f "$1" >/dev/null 2>&1
}

ssh_marker_content_for_user() {
    marker_user=$1
    case "$marker_user" in
        "" | *[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    printf '%s\n' "LADLE_SSH_KEY_LOGIN_VERIFIED_V2 user=$marker_user"
}

ssh_marker_matches_user() {
    marker_file=$1
    marker_user=$2
    ssh_marker_content_for_user "$marker_user" |
        /usr/bin/cmp -s - "$marker_file"
}

effective_sshd_output_is_hardened() {
    awk '
        $0 == "permitrootlogin no" { permit_root = 1 }
        $0 == "passwordauthentication no" { password = 1 }
        $0 == "kbdinteractiveauthentication no" { keyboard = 1 }
        $0 == "pubkeyauthentication yes" { public_key = 1 }
        $1 == "authenticationmethods" {
            authentication_methods_seen++
            if ($0 != "authenticationmethods publickey") {
                invalid = 1
            } else {
                authentication_methods = 1
            }
        }
        END {
            valid = !invalid && permit_root && password && keyboard
            valid = valid && public_key && authentication_methods
            valid = valid && authentication_methods_seen == 1
            exit !valid
        }
    '
}

_sshd_config_file_has_no_match() (
    ssh_audit_root=$1
    ssh_audit_file=$2
    ssh_audit_depth=$3

    if [ "$ssh_audit_depth" -gt 32 ] ||
        [ ! -f "$ssh_audit_file" ] ||
        [ ! -r "$ssh_audit_file" ]; then
        exit 1
    fi

    while IFS= read -r ssh_config_line ||
        [ -n "$ssh_config_line" ]; do
        ssh_config_line=$(
            printf '%s\n' "$ssh_config_line" |
                /usr/bin/sed \
                    -e 's/^[[:space:]]*//' \
                    -e 's/[[:space:]]*#.*$//'
        )
        [ -n "$ssh_config_line" ] || continue
        ssh_keyword=${ssh_config_line%%[[:space:]]*}
        case "$ssh_keyword" in
            [Mm][Aa][Tt][Cc][Hh]) exit 1 ;;
            [Ii][Nn][Cc][Ll][Uu][Dd][Ee])
                ssh_include_arguments=${ssh_config_line#"$ssh_keyword"}
                case "$ssh_include_arguments" in
                    *["'\\"]*) exit 1 ;;
                esac
                set -- $ssh_include_arguments
                [ "$#" -gt 0 ] || exit 1
                for ssh_include_pattern do
                    case "$ssh_include_pattern" in
                        /*) ;;
                        *) ssh_include_pattern=$ssh_audit_root/$ssh_include_pattern ;;
                    esac
                    for ssh_included_file in $ssh_include_pattern; do
                        [ -e "$ssh_included_file" ] || continue
                        _sshd_config_file_has_no_match \
                            "$ssh_audit_root" \
                            "$ssh_included_file" \
                            "$((ssh_audit_depth + 1))" ||
                            exit 1
                    done
                done
                ;;
        esac
    done <"$ssh_audit_file"
)

sshd_config_tree_has_no_match() {
    ssh_main_config=$1
    ssh_config_root=$(CDPATH= cd -- "$(dirname -- "$ssh_main_config")" && pwd -P) ||
        return 1
    _sshd_config_file_has_no_match "$ssh_config_root" "$ssh_main_config" 0
}

reload_ssh_transaction() {
    ssh_reload_command=$1
    ssh_restore_command=$2
    ssh_validate_command=$3
    ssh_commit_command=$4
    ssh_reload_signal_pending=false
    ssh_reload_status=0

    # Defer termination until disk and daemon have reached the same policy.
    trap 'ssh_reload_signal_pending=true' HUP INT TERM
    if "$ssh_reload_command"; then
        if "$ssh_commit_command"; then
            :
        elif "$ssh_restore_command" &&
            "$ssh_validate_command" &&
            "$ssh_reload_command"; then
            ssh_reload_status=1
        else
            ssh_reload_status=2
        fi
    elif "$ssh_restore_command" &&
        "$ssh_validate_command" &&
        "$ssh_reload_command"; then
        ssh_reload_status=1
    else
        ssh_reload_status=2
    fi
    trap 'exit 1' HUP INT TERM

    if [ "$ssh_reload_signal_pending" = true ]; then
        return 3
    fi
    return "$ssh_reload_status"
}
