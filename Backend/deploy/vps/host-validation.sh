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
