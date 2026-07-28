#!/bin/sh
set -eu
umask 077

dropin=/etc/ssh/sshd_config.d/00-ladle-hardening.conf

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

print_gate_instructions() {
    cat >&2 <<EOF
SSH lockout prevention:
1. Keep session A open throughout this operation.
2. From a separate session B, prove public-key login for the target user.
3. In session B, create the marker as root with mode 0600 and exact content:
   printf '%s\\n' '$marker_content' | sudo tee ABSOLUTE_MARKER_PATH >/dev/null
   sudo chmod 0600 ABSOLUTE_MARKER_PATH
4. Back in session A, preserve its connection context and run:
   sudo --preserve-env=SSH_CONNECTION $0 ABSOLUTE_MARKER_PATH
The marker is an operator assertion; this script cannot infer session B's
authentication method.
EOF
}

if [ "$(id -u)" -ne 0 ]; then
    die "Run harden-ssh.sh as root."
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
host_validation_source=$script_directory/host-validation.sh
if [ ! -f "$host_validation_source" ] || [ -L "$host_validation_source" ]; then
    die "Missing regular host validation library: $host_validation_source"
fi
. "$host_validation_source"

target_user=${LADLE_SSH_USER:-${SUDO_USER:-ubuntu}}
case "$target_user" in
    "" | *[!A-Za-z0-9_.-]*) die "The SSH target user name is unsafe." ;;
esac
target_uid=$(id -u "$target_user" 2>/dev/null) ||
    die "SSH target user does not exist: $target_user"
if [ "$target_uid" -eq 0 ]; then
    die "SSH hardening requires a non-root target user."
fi
marker_content=$(ssh_marker_content_for_user "$target_user") ||
    die "Cannot construct the target-bound SSH verification marker."

if [ "$#" -ne 1 ]; then
    print_gate_instructions
    die "Usage: sudo $0 /absolute/path/to/key-login-marker"
fi

marker_path=$1
print_gate_instructions
case "$marker_path" in
    /*) ;;
    *) die "The verification marker path must be absolute." ;;
esac
if [ ! -f "$marker_path" ] || [ -L "$marker_path" ]; then
    die "The verification marker must be a regular, non-symlink file."
fi
marker_canonical=$(readlink -f -- "$marker_path") ||
    die "Cannot resolve the verification marker."
if [ "$marker_canonical" != "$marker_path" ]; then
    die "The verification marker path must be canonical and contain no symlinks."
fi
marker_metadata=$(stat -c "%u:%a" -- "$marker_path") ||
    die "Cannot inspect the verification marker."
if [ "$marker_metadata" != "0:600" ]; then
    die "The verification marker must be owned by root with mode 0600."
fi

dropin_candidate=
dropin_previous=
configuration_pending=false

cleanup() {
    if [ "$configuration_pending" = true ]; then
        if ! restore_previous_dropin; then
            printf '%s\n' \
                "Automatic SSH rollback failed; keep session A open." \
                "Preserved backup: ${dropin_previous:-none}" >&2
        fi
    fi
    if [ -n "$dropin_candidate" ]; then
        rm -f -- "$dropin_candidate"
    fi
    if [ "$configuration_pending" = false ] &&
        [ -n "$dropin_previous" ]; then
        rm -f -- "$dropin_previous"
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

if ! ssh_marker_matches_user "$marker_path" "$target_user"; then
    die "The verification marker is invalid for target user $target_user."
fi
marker_parent=$(dirname -- "$marker_path")
marker_parent_metadata=$(stat -c "%u:%a" -- "$marker_parent") ||
    die "Cannot inspect the verification marker directory."
case "$marker_parent_metadata" in
    "0:700" | "0:711" | "0:750" | "0:755") ;;
    *) die "The verification marker directory permissions are unsafe." ;;
esac

target_home=$(getent passwd "$target_user" | awk -F: 'NR == 1 { print $6 }')
case "$target_home" in
    /*) ;;
    *) die "The SSH target user has no safe absolute home directory." ;;
esac

ssh_directory=$target_home/.ssh
authorized_keys=$ssh_directory/authorized_keys
if [ ! -d "$ssh_directory" ] || [ -L "$ssh_directory" ]; then
    die "The target user's .ssh directory must be a real directory."
fi
ssh_directory_metadata=$(stat -c "%u:%a" -- "$ssh_directory") ||
    die "Cannot inspect the target user's .ssh directory."
case "$ssh_directory_metadata" in
    "$target_uid:500" | "$target_uid:700") ;;
    *) die "The .ssh directory must be target-owned with mode 0500 or 0700." ;;
esac
if [ ! -f "$authorized_keys" ] || [ -L "$authorized_keys" ]; then
    die "Install a regular authorized_keys file before hardening SSH."
fi
authorized_metadata=$(stat -c "%u:%a" -- "$authorized_keys") ||
    die "Cannot inspect authorized_keys."
case "$authorized_metadata" in
    "$target_uid:400" | "$target_uid:600") ;;
    *) die "authorized_keys must be target-owned with mode 0400 or 0600." ;;
esac
if ! authorized_keys_has_valid_key "$authorized_keys"; then
    die "authorized_keys contains no supported installed public key."
fi

if ! sshd_config_tree_has_no_match /etc/ssh/sshd_config; then
    die "Active or unauditable SSH Match policy found; manual audit is required."
fi

set -f
set -- ${SSH_CONNECTION:-}
set +f
if [ "$#" -ne 4 ]; then
    die "SSH_CONNECTION is required to validate the active public session."
fi
ssh_client_address=$1
ssh_client_port=$2
ssh_server_address=$3
ssh_server_port=$4
case "$ssh_client_address:$ssh_server_address" in
    *[!0-9A-Fa-f:.]*) die "SSH_CONNECTION contains unsafe addresses." ;;
esac
case "$ssh_client_port:$ssh_server_port" in
    *[!0-9:]*) die "SSH_CONNECTION contains unsafe ports." ;;
esac

install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
dropin_candidate=$(mktemp /etc/ssh/sshd_config.d/.ladle-hardening.XXXXXX)
cat >"$dropin_candidate" <<'LADLE_SSH_HARDENING'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
LADLE_SSH_HARDENING
chmod 0644 "$dropin_candidate"
chown root:root "$dropin_candidate"

had_previous=false
if [ -L "$dropin" ]; then
    die "Refusing to replace a symlink SSH hardening drop-in."
fi
if [ -e "$dropin" ]; then
    if [ ! -f "$dropin" ] || [ -L "$dropin" ]; then
        die "Refusing to replace a non-regular SSH hardening drop-in."
    fi
    dropin_previous=$(mktemp /etc/ssh/sshd_config.d/.ladle-previous.XXXXXX)
    cp -p -- "$dropin" "$dropin_previous"
    had_previous=true
fi

restore_previous_dropin() {
    if [ "$had_previous" = true ]; then
        mv -f -- "$dropin_previous" "$dropin" || return 1
        dropin_previous=
    else
        rm -f -- "$dropin" || return 1
    fi
    configuration_pending=false
}

configuration_pending=true
mv -f -- "$dropin_candidate" "$dropin"
dropin_candidate=

if ! /usr/sbin/sshd -t; then
    restore_previous_dropin ||
        die "SSH configuration validation and rollback both failed; keep session A open."
    die "SSH configuration validation failed; the previous drop-in was restored."
fi

validate_effective_configuration() {
    connection_user=$1
    connection_address=$2
    local_address=$3
    local_port=$4
    connection_context="user=$connection_user,host=localhost,addr=$connection_address,laddr=$local_address,lport=$local_port"
    effective_configuration=$(
        /usr/sbin/sshd -T -C "$connection_context"
    ) || return 1
    printf '%s\n' "$effective_configuration" |
        effective_sshd_output_is_hardened
}

validate_effective_contexts() {
    context_user=$1
    validate_effective_configuration \
        "$context_user" \
        "$ssh_client_address" \
        "$ssh_server_address" \
        "$ssh_server_port" &&
        validate_effective_configuration \
            "$context_user" "198.51.100.10" "192.0.2.10" 22 &&
        validate_effective_configuration \
            "$context_user" "2001:db8::10" "2001:db8::20" 22
}

if ! validate_effective_contexts "$target_user" ||
    ! validate_effective_contexts root; then
    restore_previous_dropin ||
        die "SSH effective-policy validation and rollback both failed; keep session A open."
    die "SSH hardening is not effective; the previous drop-in was restored."
fi

reload_ssh_service() {
    systemctl reload ssh
}

validate_ssh_configuration() {
    /usr/sbin/sshd -t
}

commit_ssh_configuration() {
    configuration_pending=false
}

reload_status=0
reload_ssh_transaction \
    reload_ssh_service \
    restore_previous_dropin \
    validate_ssh_configuration \
    commit_ssh_configuration ||
    reload_status=$?
case "$reload_status" in
    0) ;;
    1) die "SSH reload failed; the previous policy was restored and reloaded." ;;
    2)
        die "SSH reload recovery failed; keep session A open and repair manually."
        ;;
    3)
        die "SSH reload was interrupted after disk and daemon were synchronized."
        ;;
    *) die "SSH reload transaction returned an unexpected status." ;;
esac

printf '%s\n' \
    "SSH hardening is active. Keep session A open until one more key login succeeds."
